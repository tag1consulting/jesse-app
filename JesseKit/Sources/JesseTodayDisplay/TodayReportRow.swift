import SwiftUI
import JesseNetworking

/// One glanceable briefing row: a linked line worth surfacing on its own.
///
/// The unseen dot is the whole point of the row's existence. A briefing section is
/// re-emitted every morning with the same wording, so "have I read today's currency
/// report" is not answerable from the text — only from the glance store, which the
/// bridge keys by DAY as well as by id so yesterday's read does not mark today's
/// re-emission. Tapping the row is what records the glance; it is not a checkbox and
/// nothing about the day file changes.
public struct TodayReportRow: View {
    let report: TodayReport
    let onGlance: () -> Void
    let onOpenLink: (TodayLink) -> Void

    public init(report: TodayReport, onGlance: @escaping () -> Void,
                onOpenLink: @escaping (TodayLink) -> Void = { _ in }) {
        self.report = report
        self.onGlance = onGlance
        self.onOpenLink = onOpenLink
    }

    public var body: some View {
        Button(action: onGlance) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: TodaySemantics.reportSymbol(kind: report.kind))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.title)
                        // An unseen row leads; a seen one recedes. Weight rather than
                        // color, so the distinction survives a colorblind viewer and
                        // the dot is a second, redundant signal rather than the only one.
                        .font(.subheadline)
                        .fontWeight(report.seen ? .regular : .semibold)
                        .foregroundStyle(report.seen ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(.primary))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    TodayLinkChips(links: report.links, onOpen: onOpenLink)
                }
                Spacer(minLength: 0)
                if !report.seen {
                    Circle()
                        .fill(.tint)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(report.title)
        .accessibilityValue(report.seen ? "Seen" : "Unseen")
        .accessibilityHint("Marks this as seen")
    }
}
