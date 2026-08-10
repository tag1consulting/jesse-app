import SwiftUI

/// The optional one-line note attached to a completion.
///
/// **The two-tap rule.** Checking a box must never cost more than two taps: tap the
/// box, and that is the check. The sheet exists because evidence is genuinely useful
/// — it is what gets written into the vault as `(completed YYYY-MM-DD: …)` when the
/// item is later propagated to its project file — but it must never become a toll on
/// the common case. So the sheet's PRIMARY action is "Done, no note": one tap, the
/// check lands with no evidence, and the field is never touched. Typing is the opt-in
/// path, and the field is deliberately NOT focused on appear, because an auto-raised
/// keyboard is itself a demand for attention.
///
/// The cap mirrors the bridge's `MAX_EVIDENCE_CHARS`: evidence is a note about what
/// was done, not a document, and the bridge truncates past it. Enforcing the same
/// limit here means the user sees what will actually be stored rather than typing
/// into text that will be silently dropped.
public struct EvidenceSheet: View {
    /// The same cap the bridge applies (`todaywrite::MAX_EVIDENCE_CHARS`). Kept in
    /// sync by hand — the bridge does not publish it — so a change there is a change
    /// here.
    public static let maxCharacters = 500

    let itemLead: String
    let onComplete: (String?) -> Void
    let onCancel: () -> Void

    @State private var note = ""

    public init(itemLead: String, onComplete: @escaping (String?) -> Void,
                onCancel: @escaping () -> Void) {
        self.itemLead = itemLead
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    private var trimmed: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Completing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(itemLead)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("What did you do? (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                    .onChange(of: note) { _, new in
                        if new.count > Self.maxCharacters {
                            note = String(new.prefix(Self.maxCharacters))
                        }
                    }
                if trimmed.count > Self.maxCharacters - 100 {
                    Text("\(Self.maxCharacters - trimmed.count) characters left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                // THE FAST PATH, and it is the visually primary one on purpose: a bare
                // check is the common case and must be the easiest thing on the sheet.
                Button {
                    onComplete(nil)
                } label: {
                    Text("Done, no note").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onComplete(trimmed.isEmpty ? nil : trimmed)
                } label: {
                    Text("Done with note").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(trimmed.isEmpty)

                Button("Cancel", role: .cancel, action: onCancel)
                    .controlSize(.large)
            }
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
