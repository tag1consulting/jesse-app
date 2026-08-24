import SwiftUI
import JesseCore

// **The queue, said out loud.**
//
// A capture queue whose contents are invisible is worse than no queue at all: the user
// is told "saved offline", and then has to take it on faith for the rest of the outage —
// and when one of those changes turns out to be un-replayable, they never learn. So
// everything the app is holding on someone's behalf is one collapsed row away, with its
// state, its reason if it has one, and the two things a person can actually do about it.
//
// It is a `Section` rather than a sheet or a badge, and it sits at the TOP of the day,
// because the whole claim it makes is "these changes are not in the vault yet". A thing
// you have to go and find would not be making that claim.

/// The collapsible "Pending (n)" block.
///
/// Rendered by both dashboards — the Today tab over its day-file intents, the Health tab
/// over its diet ones — from the same source, so the two cannot grow different ideas of
/// what a queued change looks like.
///
/// A bare `DisclosureGroup` and NOT a `Section`, deliberately: the Today tab drops it in
/// as a list row, and the Health tab (whose dashboard is a scroll view, not a list) puts
/// it in a `safeAreaInset`. Wrapping it in a `Section` here would make the second of
/// those impossible and would have forced a second implementation.
public struct TodayPendingSection: View {
    private let intents: [PendingIntentRecord]
    private let onRetry: (PendingIntentRecord) -> Void
    private let onDiscard: (PendingIntentRecord) -> Void
    private let onTell: ((PendingIntentRecord) -> Void)?

    /// `onTell` is optional because the fallback needs a conversation to send into, and
    /// not every shell has one (the Mac's Today window does not own a `RunCoordinator`).
    /// Absent, the button is simply not offered — never offered and inert.
    public init(intents: [PendingIntentRecord],
                onRetry: @escaping (PendingIntentRecord) -> Void,
                onDiscard: @escaping (PendingIntentRecord) -> Void,
                onTell: ((PendingIntentRecord) -> Void)? = nil) {
        self.intents = intents
        self.onRetry = onRetry
        self.onDiscard = onDiscard
        self.onTell = onTell
    }

    /// Collapsed by default. During an ordinary outage this block is bookkeeping the
    /// user has already been told about once, by the notice under the tap; expanded by
    /// default it would push the day itself off the screen.
    @State private var isExpanded = false

    /// Anything refused is not bookkeeping — it is a change that will not happen unless
    /// someone acts — so the block opens itself for those and says so in colour.
    private var hasRefusal: Bool { intents.contains { $0.state == .refused } }

    public var body: some View {
        if !intents.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(intents) { intent in
                    TodayPendingRow(intent: intent,
                                    onRetry: { onRetry(intent) },
                                    onDiscard: { onDiscard(intent) },
                                    onTell: onTell.map { action in { action(intent) } })
                }
            } label: {
                header
            }
            .task(id: hasRefusal) {
                // Opened when a refusal appears, and never closed again by this: a user
                // who collapsed the block after reading a refusal meant it.
                if hasRefusal { isExpanded = true }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: hasRefusal ? "exclamationmark.arrow.triangle.2.circlepath"
                                         : "arrow.up.circle")
                .foregroundStyle(hasRefusal ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text("Pending (\(intents.count))")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
        }
        .accessibilityLabel(hasRefusal
            ? "Pending changes, \(intents.count), some refused"
            : "Pending changes, \(intents.count)")
    }
}

/// One queued, replaying or refused change.
struct TodayPendingRow: View {
    let intent: PendingIntentRecord
    let onRetry: () -> Void
    let onDiscard: () -> Void
    /// Present only for a refusal that has something worth saying to the agent.
    let onTell: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(intent.kind.label)
                    .font(.caption.weight(.medium))
                Text(intent.createdAtClock)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(stateLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                    .foregroundStyle(.secondary)
            }
            if let subject {
                Text(subject)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = intent.refusalReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if intent.state == .refused {
                    Button("Retry", action: onRetry).font(.caption)
                    if let onTell {
                        Button("Tell Jesse", action: onTell).font(.caption)
                    }
                }
                Button("Discard", role: .destructive, action: onDiscard).font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The words the change was about: the item's lead, or a quick log's own sentence.
    private var subject: String? {
        if let lead = intent.leadText, !lead.isEmpty { return lead }
        if let text = intent.payload.text, !text.isEmpty { return text }
        return nil
    }

    private var symbol: String {
        switch intent.kind {
        case .check: return "checkmark.circle"
        case .uncheck: return "circle"
        case .defer: return "moon.zzz"
        case .undefer: return "arrow.uturn.backward"
        case .move: return "arrow.up.arrow.down"
        case .quickLog: return "fork.knife"
        case .startNewDay: return "sun.horizon"
        case .processUpdates: return "arrow.up.forward.square"
        }
    }

    private var tint: AnyShapeStyle {
        intent.state == .refused ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
    }

    private var stateLabel: String {
        switch intent.state {
        case .queued: return "Waiting"
        case .replaying: return "Sending"
        case .applied: return "Sent"
        case .refused: return "Not applied"
        }
    }
}
