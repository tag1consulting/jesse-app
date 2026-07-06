import ActivityKit
import WidgetKit
import SwiftUI

/// Renders the in-flight-turn Live Activity: a Lock Screen / banner presentation
/// and the three Dynamic Island presentations (expanded, compact, minimal). Elapsed
/// time is a self-updating `Text(…, style: .timer)` anchored to the turn's start,
/// so the app never has to push a per-second update.
struct JesseTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JesseTurnActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color(.systemBackground).opacity(0.6))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.modeLabel, systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.threadTitle)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(context.state.activityLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(.tint)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "sparkles").foregroundStyle(.tint)
            }
        }
    }
}

/// The Lock Screen / notification-banner face of the activity.
private struct LockScreenView: View {
    let attributes: JesseTurnActivityAttributes
    let state: JesseTurnActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(attributes.threadTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(state.startedAt, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 64, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(state.activityLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
