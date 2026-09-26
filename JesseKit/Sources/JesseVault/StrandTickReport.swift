import Foundation

// A TICK IN A STRAND NOTE, AS THE OLD STRAND ROUTE NEEDS IT.
//
// On 2026-09-24 a tick of Family P1 in this reader was written, logged and drawn, and never
// reached the Studio: the file this app writes is Obsidian's own copy ON THE PHONE, and
// Obsidian iOS's Sync does not see a file another app changed inside its folder. Ticks were
// first reported to `POST /jesse/strands/{slug}/ticks` from an outbox of their own.
//
// That outbox is gone. Every write, a tick included, is now a record in `VaultWriteOutbox`,
// applied by `POST /jesse/vault/writes`, which starts the same turn for a strand tick
// through the same (note, id) ledger. What stays here is the REPORT: the note and step a
// tick names, worked out on the device, which the outbox sends the old way only to a
// bridge that does not have the write route yet.

/// One tick, as the bridge needs it: which note, which step, which way.
public struct StrandTickReport: Codable, Equatable, Sendable {
    /// The note's slug: `Family` for `Strands/Family.md`.
    public let note: String
    /// The step's bold id: `P1`.
    public let id: String
    public let checked: Bool

    public init(note: String, id: String, checked: Bool) {
        self.note = note
        self.id = id
        self.checked = checked
    }

    /// The report for setting the box on 1-based `line` of `text`, the note at vault
    /// relative `path`, to `checked` — or nil when that is not a strand step.
    ///
    /// A strand step is a checkbox line with a bold id, in a note directly under
    /// `Strands/`, in a section a tick closes: `## Queue`, `## Drafts`, `## Running` or
    /// `### Later` under them. The nearest heading above the line decides, which is the
    /// reading the bridge's parser gives both note layouts. A line in `## Done` or
    /// `### Done` is already closed, and a checkbox anywhere else in the note is not a
    /// step.
    public static func forTick(path: String, text: String, line: Int,
                               checked: Bool) -> StrandTickReport? {
        guard let note = slug(path: path) else { return nil }
        let lines = VaultCheckboxEdit.lines(text)
        guard line >= 1, line <= lines.count,
              VaultCheckboxEdit.box(in: lines[line - 1]) != nil,
              let id = stepID(lines[line - 1]),
              isOpenSection(lines[..<(line - 1)])
        else { return nil }
        return StrandTickReport(note: note, id: id, checked: checked)
    }

    /// `Family` for `Strands/Family.md`. Nil for anything deeper (`Strands/archive/…`),
    /// anything that is not markdown, and a dot file.
    static func slug(path: String) -> String? {
        let parts = VaultWriteExemption.normalised(path).split(separator: "/")
        guard parts.count == 2, parts[0] == "Strands",
              parts[1].hasSuffix(".md"), !parts[1].hasPrefix(".") else { return nil }
        let slug = String(parts[1].dropLast(3))
        return slug.isEmpty ? nil : slug
    }

    /// The first `**bold**` span after the box, the way the bridge reads an id.
    static func stepID(_ line: String) -> String? {
        guard let close = line.range(of: "]") else { return nil }
        let rest = line[close.upperBound...]
        guard let open = rest.range(of: "**"),
              let end = rest[open.upperBound...].range(of: "**") else { return nil }
        let id = rest[open.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    /// Whether the nearest `##` or `###` heading above the line opens a section whose
    /// lines a tick closes.
    static func isOpenSection(_ above: ArraySlice<String>) -> Bool {
        for raw in above.reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let heading: Substring
            if line.hasPrefix("### ") {
                heading = line.dropFirst(4)
            } else if line.hasPrefix("## ") {
                heading = line.dropFirst(3)
            } else {
                continue
            }
            let name = heading.trimmingCharacters(in: .whitespaces).lowercased()
            return ["queue", "drafts", "running", "later"].contains(name)
        }
        return false
    }
}

/// What the bridge said about one report.
public enum StrandTickDelivery: Equatable, Sendable {
    /// Recorded, or already handled. Either way it leaves the outbox.
    case delivered
    /// The bridge will never accept it (no such note or step there). It leaves the
    /// outbox too: keeping it would resend a report that can only ever be refused.
    case refused
}

/// Whatever can tell the bridge. A thrown error means "not reached": the report stays.
public protocol StrandTickReporting: Sendable {
    func reportStrandTick(_ report: StrandTickReport) async throws -> StrandTickDelivery
}
