import Foundation

// A TICK IN A STRAND NOTE IS TOLD TO THE BRIDGE, NOT ONLY WRITTEN.
//
// On 2026-09-24 a tick of Family P1 in this reader was written, logged and drawn, and never
// reached the Studio. The file this app writes is Obsidian's own copy ON THE PHONE, and the
// only thing that carries it to the Studio is Obsidian iOS's Sync, which does not see a
// file another app changed inside its folder. So "written" here meant "written to a copy
// nobody else would read", and the step it closed stayed open.
//
// The tick still goes through the guarded write exactly as before: that is the change the
// person sees, and the copy Obsidian opens next. What this adds is a REPORT of it — note,
// step id, ticked or not — to `POST /jesse/strands/{slug}/ticks`, which starts the turn
// that closes the step on the Studio. It does not depend on Obsidian at all, and the
// bridge keys it on (note, id), so the same tick arriving later through Sync starts
// nothing a second time.
//
// A REPORT THAT CANNOT BE SENT IS KEPT, not dropped. A tick made on a train is a tick, and
// the bridge's settle window means one delivered an hour late is handled like one
// delivered at once. The outbox is written before anything is sent, sent in order (an
// untick must never overtake its own tick), and emptied only by an answer from the bridge.

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

/// The reports not yet answered, in order, persisted across launches.
public actor StrandTickOutbox {

    /// The one the reader uses. Configured by each app shell with its bridge client.
    public static let shared = StrandTickOutbox()

    public static let defaultsKey = "jesse.strands.tickOutbox"

    private let defaults: UserDefaults
    private let key: String
    private var makeReporter: (@Sendable () async -> (any StrandTickReporting)?)?
    /// The last flush started. Each new one waits for it, so flushes form a chain.
    private var last: Task<Void, Never>?

    /// `suiteName` nil is the app's standard defaults. A suite NAME rather than a
    /// `UserDefaults`, so the actor opens its own and nothing unsendable crosses into it.
    public init(suiteName: String? = nil, key: String = StrandTickOutbox.defaultsKey) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.key = key
    }

    /// Hand the outbox a way to reach the bridge. A closure rather than a client because
    /// the shells rebuild their client from settings on every call, and async because the
    /// Mac's settings live on the main actor.
    public func configure(reporter: @escaping @Sendable () async -> (any StrandTickReporting)?) {
        makeReporter = reporter
    }

    /// Everything still waiting for an answer, oldest first.
    public var queued: [StrandTickReport] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([StrandTickReport].self, from: data)
        else { return [] }
        return list
    }

    /// Keep `report`. Written before any send, so a crash or a dead network loses nothing.
    public func enqueue(_ report: StrandTickReport) {
        store(queued + [report])
    }

    /// Send what is waiting, in order, until the queue is empty or the bridge cannot be
    /// reached. One send at a time: a call made while another is sending waits for it,
    /// then sends whatever that one left, so two ticks in a row can never race each
    /// other to the bridge or be sent twice.
    ///
    /// A CHAIN, not a flag: each flush waits for the one before it and then drains once,
    /// so there is no marker to clear and nothing for a waiter to spin on.
    public func flush() async {
        let previous = last
        let task = Task {
            await previous?.value
            await self.drain()
        }
        last = task
        await task.value
    }

    private func drain() async {
        guard let reporter = await makeReporter?() else { return }
        while let next = queued.first {
            do {
                _ = try await reporter.reportStrandTick(next)
            } catch {
                // Not reached. It stays, first in line, for the next flush.
                return
            }
            var rest = queued
            if let at = rest.firstIndex(of: next) { rest.remove(at: at) }
            store(rest)
        }
    }

    private func store(_ list: [StrandTickReport]) {
        if list.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        }
    }
}
