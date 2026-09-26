import SwiftUI

// WHAT THE STUDIO HAS NOT TAKEN YET, SAID WHERE THE NOTE IS.
//
// A write the bridge could not place is never dropped: it waits in the outbox with both
// versions until a person chooses. This is the one view that shows it, above the note it
// belongs to and in the diagnostics screen, so the two places cannot describe the same
// conflict differently.

/// The words, in one place.
public enum VaultWriteNoticeText {
    public static func pending(_ count: Int) -> String {
        count == 1
            ? "1 change from this device hasn't reached the Studio yet."
            : "\(count) changes from this device haven't reached the Studio yet."
    }

    public static func conflict(_ entry: VaultOutboxEntry) -> String {
        "Your \(entry.record.kind.noun) of \(VaultWikiLink.basename(entry.record.path)) conflicts with the Studio's copy."
    }

    public static let keepMine = "Keep mine"
    public static let takeStudios = "Take the Studio's"
}

extension VaultEditKind {
    /// "your edit", "your tick".
    var noun: String {
        switch self {
        case .capture: return "capture"
        case .tick: return "tick"
        case .untick: return "untick"
        case .edit: return "edit"
        }
    }
}

/// The pending line and every conflict, for one note or for the whole outbox.
public struct VaultWriteNotices: View {
    let entries: [VaultOutboxEntry]
    let keepMine: (VaultOutboxEntry) -> Void
    let takeStudios: (VaultOutboxEntry) -> Void

    public init(entries: [VaultOutboxEntry],
                keepMine: @escaping (VaultOutboxEntry) -> Void,
                takeStudios: @escaping (VaultOutboxEntry) -> Void) {
        self.entries = entries
        self.keepMine = keepMine
        self.takeStudios = takeStudios
    }

    public var body: some View {
        let queued = entries.filter { !$0.isConflicted }.count
        if queued > 0 {
            Label(VaultWriteNoticeText.pending(queued), systemImage: "arrow.up.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(entries.filter(\.isConflicted)) { entry in
            VaultWriteConflictRow(entry: entry,
                                  keepMine: { keepMine(entry) },
                                  takeStudios: { takeStudios(entry) })
        }
    }
}

/// One conflict: the one line, both versions on request, and the two choices.
public struct VaultWriteConflictRow: View {
    let entry: VaultOutboxEntry
    let keepMine: () -> Void
    let takeStudios: () -> Void
    @State private var comparing = false

    public init(entry: VaultOutboxEntry, keepMine: @escaping () -> Void,
                takeStudios: @escaping () -> Void) {
        self.entry = entry
        self.keepMine = keepMine
        self.takeStudios = takeStudios
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(VaultWriteNoticeText.conflict(entry), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Compare the two versions", isExpanded: $comparing) {
                VStack(alignment: .leading, spacing: 8) {
                    version("This device", entry.record.deviceVersion)
                    version("The Studio", entry.studioVersion ?? "")
                }
            }
            .font(.caption)
            HStack(spacing: 10) {
                Button(VaultWriteNoticeText.keepMine, action: keepMine)
                    .buttonStyle(.bordered)
                Button(VaultWriteNoticeText.takeStudios, action: takeStudios)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    private func version(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).fontWeight(.semibold)
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
    }
}
