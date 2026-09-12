import Foundation
import Observation

// Live usage and quota per BILLING ACCOUNT (`GET /jesse/usage`, bridge 0.137.0).
//
// Quota belongs to an account, not a model: `ModelInfo.usageScope` names the account a model
// spends (`claude-subscription`, `codex-chatgpt`, `fireworks`), and `UsageState` holds one
// `QuotaScope` per account. This file carries the wire types, the ONE in-memory store the
// picker and Settings share, and the pure presentation rules both apps render from, so the
// iPhone and the Mac cannot drift on what a usage line says.

// MARK: - Wire types

/// One limit window: how much of it is used, and when it resets.
public struct QuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// `5 hours`, `7 days`, a model name, `extra usage`.
    public let label: String
    /// 0 to 100.
    public let usedPercent: Double
    public let resetsAtMs: Int64?
    /// The provider's own word for the window's state when it gave one (`allowed`,
    /// `allowed_warning`, `rejected`), else nil.
    public let status: String?

    public init(id: String, label: String, usedPercent: Double, resetsAtMs: Int64? = nil,
                status: String? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAtMs = resetsAtMs
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, label, status
        case usedPercent = "used_percent"
        case resetsAtMs = "resets_at_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        usedPercent = try c.decodeIfPresent(Double.self, forKey: .usedPercent) ?? 0
        resetsAtMs = try c.decodeIfPresent(Int64.self, forKey: .resetsAtMs)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }
}

/// Month to date spend on a pay as you go account. There is no balance: Fireworks exposes none.
public struct QuotaSpend: Codable, Equatable, Sendable {
    public let monthToDateUsd: Double
    public let byModelUsd: [String: Double]
    public let periodStartMs: Int64
    /// Some of the figure was computed by the bridge from token counts and the price deck,
    /// because the provider reported no cost for it. Rendered as "about".
    public let estimated: Bool

    public init(monthToDateUsd: Double, byModelUsd: [String: Double] = [:],
                periodStartMs: Int64 = 0, estimated: Bool = false) {
        self.monthToDateUsd = monthToDateUsd
        self.byModelUsd = byModelUsd
        self.periodStartMs = periodStartMs
        self.estimated = estimated
    }

    enum CodingKeys: String, CodingKey {
        case estimated
        case monthToDateUsd = "month_to_date_usd"
        case byModelUsd = "by_model_usd"
        case periodStartMs = "period_start_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monthToDateUsd = try c.decodeIfPresent(Double.self, forKey: .monthToDateUsd) ?? 0
        byModelUsd = try c.decodeIfPresent([String: Double].self, forKey: .byModelUsd) ?? [:]
        periodStartMs = try c.decodeIfPresent(Int64.self, forKey: .periodStartMs) ?? 0
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
    }
}

/// One account's last known state: a `GET /jesse/usage` entry, and the same shape a turn's
/// `provenance.quota` carries. Every field but `id` defaults, so a bridge that adds or omits
/// one never costs the whole list.
public struct QuotaScope: Codable, Equatable, Sendable, Identifiable {
    /// `claude-subscription` | `codex-chatgpt` | `fireworks`, kept raw so a future account
    /// still decodes and renders.
    public let id: String
    public let label: String
    /// The registry ids of the models that bill this account.
    public let models: [String]
    public let windows: [QuotaWindow]
    public let spend: QuotaSpend?
    public let plan: String?
    /// When the data was last updated (by a fetch or by a turn), Unix millis. 0 when never.
    public let fetchedAtMs: Int64
    /// `fetched` | `turn`.
    public let source: String
    /// The last failure's text, kept beside the last good data.
    public let error: String?
    /// Any window at 90 percent or more, or any window `rejected`.
    public let warning: Bool
    /// How long the bridge treats this snapshot as fresh. nil from a bridge that does not
    /// say, in which case `QuotaPresentation` uses the bridge's defaults.
    public let ttlSecs: Int?

    public init(id: String, label: String? = nil, models: [String] = [],
                windows: [QuotaWindow] = [], spend: QuotaSpend? = nil, plan: String? = nil,
                fetchedAtMs: Int64 = 0, source: String = "fetched", error: String? = nil,
                warning: Bool = false, ttlSecs: Int? = nil) {
        self.id = id
        self.label = label ?? id
        self.models = models
        self.windows = windows
        self.spend = spend
        self.plan = plan
        self.fetchedAtMs = fetchedAtMs
        self.source = source
        self.error = error
        self.warning = warning
        self.ttlSecs = ttlSecs
    }

    enum CodingKeys: String, CodingKey {
        case id, label, models, windows, spend, plan, source, error, warning
        case fetchedAtMs = "fetched_at_ms"
        case ttlSecs = "ttl_secs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        windows = try c.decodeIfPresent([QuotaWindow].self, forKey: .windows) ?? []
        spend = try c.decodeIfPresent(QuotaSpend.self, forKey: .spend)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        fetchedAtMs = try c.decodeIfPresent(Int64.self, forKey: .fetchedAtMs) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "fetched"
        error = try c.decodeIfPresent(String.self, forKey: .error)
        warning = try c.decodeIfPresent(Bool.self, forKey: .warning) ?? false
        ttlSecs = try c.decodeIfPresent(Int.self, forKey: .ttlSecs)
    }
}

/// The `GET /jesse/usage` payload: one scope per account a configured model bills to.
public struct UsageState: Codable, Equatable, Sendable {
    public var scopes: [QuotaScope]

    public init(scopes: [QuotaScope]) { self.scopes = scopes }

    enum CodingKeys: String, CodingKey { case scopes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scopes = try c.decodeIfPresent([QuotaScope].self, forKey: .scopes) ?? []
    }

    /// The account `model` bills: by its `usageScope`, or, from a bridge row that did not say,
    /// by the scope that lists it. nil when it bills none.
    public func scope(for model: ModelInfo) -> QuotaScope? {
        if let id = model.usageScope { return scopes.first { $0.id == id } }
        return scopes.first { $0.models.contains(model.id) }
    }

    /// This state with `scope` in place of the entry of the same id, or appended when new.
    public func replacing(_ scope: QuotaScope) -> UsageState {
        var next = scopes
        if let i = next.firstIndex(where: { $0.id == scope.id }) {
            next[i] = scope
        } else {
            next.append(scope)
        }
        return UsageState(scopes: next)
    }
}

// MARK: - The store

/// The ONE in-memory usage state both the picker and Settings render, per app process.
///
/// Filled from exactly three places, which is the whole of the app's quota traffic: the
/// picker's one shot load after its model list arrives, Settings (on appear, inside its
/// existing visible poll, and on Refresh), and every delivered turn's `provenance.quota`, which
/// replaces its account's scope for free. Never from a background refresh, the thread list,
/// the watch or a widget. Nothing is persisted: a relaunch asks again the first time a surface
/// that shows quota appears.
@MainActor
@Observable
public final class UsageStore {
    public static let shared = UsageStore()

    public private(set) var state: UsageState?

    public init(state: UsageState? = nil) {
        self.state = state
    }

    /// A whole `GET /jesse/usage` answer.
    public func replace(_ state: UsageState) {
        self.state = state
    }

    /// One account's scope, from a turn's provenance. A no-op for nil, so a caller can hand
    /// over `reply.provenance?.quota` unconditionally.
    public func apply(_ scope: QuotaScope?) {
        guard let scope else { return }
        state = (state ?? UsageState(scopes: [])).replacing(scope)
    }
}

// MARK: - Presentation (pure)

/// Every string a usage display renders, decided here so both apps say the same thing and a
/// test can pin it. No dash characters anywhere: these reach menu subtitles and Settings.
public enum QuotaPresentation {
    /// A snapshot older than this many TTLs reads `stale`.
    public static let staleFactor: Int64 = 3
    /// At or above this, a window is near its limit.
    public static let warningPercent: Double = 90

    /// The bridge's own defaults, for a bridge that does not report `ttl_secs`.
    public static func defaultTTLSecs(for scopeID: String) -> Int {
        scopeID == "fireworks" ? 600 : 120
    }

    public static func ttlSecs(_ scope: QuotaScope) -> Int {
        scope.ttlSecs ?? defaultTTLSecs(for: scope.id)
    }

    public static func isStale(_ scope: QuotaScope, nowMs: Int64) -> Bool {
        guard scope.fetchedAtMs > 0 else { return false }
        return nowMs - scope.fetchedAtMs > staleFactor * Int64(ttlSecs(scope)) * 1000
    }

    public static func isNearLimit(_ window: QuotaWindow) -> Bool {
        window.usedPercent >= warningPercent || window.status == "rejected"
    }

    /// The menu's short form of a window label: `5h`, `week`, `extra`, `45m`, else the label.
    public static func shortLabel(_ label: String) -> String {
        switch label {
        case "5 hours": return "5h"
        case "7 days": return "week"
        case "extra usage": return "extra"
        default: break
        }
        if label.hasSuffix(" min"), let n = Int(label.dropLast(4)) { return "\(n)m" }
        return label
    }

    public static func percentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    /// `$1.75 this month`, or `about $1.75 this month` when the bridge estimated part of it.
    public static func spendLine(_ spend: QuotaSpend) -> String {
        let amount = String(format: "$%.2f", spend.monthToDateUsd)
        return spend.estimated ? "about \(amount) this month" : "\(amount) this month"
    }

    /// **THE MENU'S USAGE LINE** for the account a row's model bills, or nil.
    ///
    /// Windows as `<short label> <n>%` (`5h 23% · week 41%`); a spend account as
    /// `$<0.00> this month`; `stale` appended when the snapshot is older than three TTLs; the
    /// error text alone when there is nothing else to show; nil for no account at all. The
    /// reset countdown is deliberately NOT here: it belongs to the Settings card.
    public static func usageLine(for scope: QuotaScope?, nowMs: Int64) -> String? {
        guard let scope else { return nil }
        var parts = scope.windows.map { "\(shortLabel($0.label)) \(percentText($0.usedPercent))" }
        if let spend = scope.spend { parts.append(spendLine(spend)) }
        guard !parts.isEmpty else {
            guard let error = scope.error, !error.isEmpty else { return nil }
            return error
        }
        if isStale(scope, nowMs: nowMs) { parts.append("stale") }
        return parts.joined(separator: " · ")
    }

    /// The Settings card's line for one window: `5 hours 23%`.
    public static func windowLine(_ window: QuotaWindow) -> String {
        "\(window.label) \(percentText(window.usedPercent))"
    }

    /// `resets in 2h 10m`, computed at render time. For the Settings card only.
    public static func resetCountdown(_ resetsAtMs: Int64?, nowMs: Int64) -> String? {
        guard let resetsAtMs else { return nil }
        let secs = (resetsAtMs - nowMs) / 1000
        guard secs > 0 else { return "resets now" }
        let minutes = (secs + 59) / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(mins)m" }
        return "resets in \(mins)m"
    }

    /// `updated 12s ago`, or nil for a snapshot never fetched.
    public static func updatedAgo(_ fetchedAtMs: Int64, nowMs: Int64) -> String? {
        guard fetchedAtMs > 0 else { return nil }
        let secs = max(0, (nowMs - fetchedAtMs) / 1000)
        if secs < 60 { return "updated \(secs)s ago" }
        if secs < 3600 { return "updated \(secs / 60)m ago" }
        return "updated \(secs / 3600)h ago"
    }

    /// The labels of the models an account covers, from the loaded model list where it can,
    /// else their ids.
    public static func modelLabels(for scope: QuotaScope, in state: ModelSwitchState?) -> [String] {
        scope.models.map { id in state?.models.first { $0.id == id }?.label ?? id }
    }

    public static func nowMs(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
