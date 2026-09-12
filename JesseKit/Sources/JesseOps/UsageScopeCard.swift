import SwiftUI
import JesseNetworking

// ONE ACCOUNT'S LIVE QUOTA, as the Usage section in Settings shows it on both platforms.
//
// Here rather than in either app because the iPhone and the Mac render the same card, and
// JesseOps is the SwiftUI module both already link. Only the `Section` wrapper, the Refresh
// button and the fetch live per platform. Every string comes from `QuotaPresentation`, and every
// relative time ("resets in 2h 10m", "updated 12s ago") is computed from `now` at render time:
// there is no timer here, and the card is redrawn when the store it reads changes.

public struct UsageScopeCard: View {
    private let scope: QuotaScope
    private let modelLabels: [String]
    private let now: Date

    public init(scope: QuotaScope, modelLabels: [String], now: Date = Date()) {
        self.scope = scope
        self.modelLabels = modelLabels
        self.now = now
    }

    public var body: some View {
        let nowMs = QuotaPresentation.nowMs(now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(scope.label)
                    .font(.headline)
                if scope.warning {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("usage near limit")
                }
                Spacer(minLength: 8)
                if let plan = scope.plan, !plan.isEmpty {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !modelLabels.isEmpty {
                Text(modelLabels.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(scope.windows) { window in
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
                        .tint(QuotaPresentation.isNearLimit(window) ? Color.orange : Color.accentColor)
                    HStack {
                        Text(QuotaPresentation.windowLine(window))
                        Spacer(minLength: 8)
                        if let reset = QuotaPresentation.resetCountdown(window.resetsAtMs,
                                                                         nowMs: nowMs) {
                            Text(reset)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                .accessibilityElement(children: .combine)
            }
            if let spend = scope.spend {
                Text(QuotaPresentation.spendLine(spend))
                    .font(.callout)
            }
            Text(footnote(nowMs: nowMs))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = scope.error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// `updated 12s ago`, plus `stale` past three TTLs.
    private func footnote(nowMs: Int64) -> String {
        var parts = [QuotaPresentation.updatedAgo(scope.fetchedAtMs, nowMs: nowMs) ?? "not checked yet"]
        if QuotaPresentation.isStale(scope, nowMs: nowMs) { parts.append("stale") }
        return parts.joined(separator: " · ")
    }
}
