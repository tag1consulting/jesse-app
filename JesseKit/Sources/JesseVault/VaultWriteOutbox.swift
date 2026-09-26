import Foundation

// EVERY WRITE THIS APP MAKES TO A NOTE IS TOLD TO THE STUDIO, NOT ONLY WRITTEN.
//
// The notes this app writes are Obsidian's own copy ON THE DEVICE, and on the phone the
// only thing that carried them to the Studio was Obsidian iOS's Sync, which does not see a
// file another app changed inside its folder. On 2026-09-24 a tick of Family P1 was
// written, logged and drawn, and never reached the Studio. Strand ticks were then also
// reported to the bridge; everything else — an edit from the editor, a CriticMarkup
// comment, a checkbox in any other note, an Inbox capture made offline — was written and
// hoped.
//
// So every write is now ALSO a record in this outbox, and the record goes to
// `POST /jesse/vault/writes`, which applies it against the Studio's CURRENT file: an edit
// merged three ways against the base the device edited, a tick found by its line's content
// when the file has shifted, a capture appended once. Three rules make it trustworthy:
//
//   * ENQUEUED BEFORE ANYTHING IS SENT, in the same step as the guarded local write. The
//     writer queues the record first and removes it only if the local write then fails;
//     if the record cannot be queued, the write is refused. So a write on the device is
//     never one the Studio will not hear about.
//   * SENT IN ORDER, one flush at a time, and a record leaves only on an answer from the
//     bridge: `applied` removes it, `conflict` keeps it marked with both versions until a
//     person chooses, `refused` is shown once and dropped. A transport failure keeps
//     everything for the next flush.
//   * PERSISTED IN APPLICATION SUPPORT, never in the vault, so a relaunch keeps the queue
//     and Obsidian never sees a file of ours.
//
// An OLDER BRIDGE answers `404` for the route. Then strand ticks still go the old way, to
// `POST /jesse/strands/{slug}/ticks`, and every record stays queued until a bridge that has
// the route answers it; the bridge's (note, id) ledger makes the second report of a strand
// tick start nothing.

// MARK: - The record

/// One write, as the bridge needs it. The fields the bridge reads are sent; `deviceText` and
/// `strandTick` are this device's own and never leave it.
public struct VaultWriteRecord: Codable, Equatable, Sendable, Identifiable {
    /// The idempotency key. Also the id of the write log's row for the same write, so the
    /// diagnostics screen can say "delivered to the bridge" about it.
    public let id: UUID
    /// Vault relative, in the BRIDGE's terms (see `VaultBridgePath`).
    public var path: String
    public var kind: VaultEditKind
    /// The hash of the file the device changed; nil for a capture and a new file.
    public var baseSHA256: String?
    /// The device's copy of that base, for an edit: what makes a merge possible.
    public var baseText: String?
    /// An edit's whole new text; a capture's entry; a tick's checkbox line as it was.
    public var text: String?
    /// A tick's 1-based line.
    public var line: Int?
    public var checked: Bool?
    public let madeAt: Date
    /// "Keep mine", after a conflict: the bridge writes the device text over what it has.
    public var force: Bool
    /// The heading a new Inbox file starts with, for a capture.
    public var prologue: String?
    /// The whole note as this device left it: what a conflict shows as "this device's
    /// version", and what "Keep mine" sends for a tick. Never sent otherwise.
    public var deviceText: String?
    /// The strand step this tick closes, for an older bridge without the write route.
    public var strandTick: StrandTickReport?

    public init(id: UUID = UUID(), path: String, kind: VaultEditKind,
                baseSHA256: String? = nil, baseText: String? = nil, text: String? = nil,
                line: Int? = nil, checked: Bool? = nil, madeAt: Date = Date(),
                force: Bool = false, prologue: String? = nil, deviceText: String? = nil,
                strandTick: StrandTickReport? = nil) {
        self.id = id
        self.path = path
        self.kind = kind
        self.baseSHA256 = baseSHA256
        self.baseText = baseText
        self.text = text
        self.line = line
        self.checked = checked
        self.madeAt = madeAt
        self.force = force
        self.prologue = prologue
        self.deviceText = deviceText
        self.strandTick = strandTick
    }

    /// The record for replacing `base` (whose stamp is `baseStamp`) with `new` in the note at
    /// device relative `localPath`.
    ///
    /// A tick carries its LINE rather than the whole note: the bridge then finds that line
    /// again by content if the Studio's file has shifted, which a whole-note edit could only
    /// do by merging. A tick whose changed line cannot be found (nothing differs, or more
    /// than one line does) is sent as the edit it actually is.
    public static func replacing(id: UUID = UUID(), localPath: String, base: String,
                                 baseStamp: VaultFileStamp, new: String,
                                 kind: VaultEditKind, madeAt: Date = Date()) -> VaultWriteRecord {
        let path = VaultBridgePath.bridge(fromLocal: localPath)
        if kind == .tick || kind == .untick, let line = changedLine(from: base, to: new) {
            let checked = kind == .tick
            let before = VaultCheckboxEdit.lines(base)[line - 1]
            return VaultWriteRecord(
                id: id, path: path, kind: kind, baseSHA256: baseStamp.digest, text: before,
                line: line, checked: checked, madeAt: madeAt, deviceText: new,
                strandTick: StrandTickReport.forTick(path: path, text: new, line: line,
                                                     checked: checked))
        }
        return VaultWriteRecord(id: id, path: path, kind: .edit, baseSHA256: baseStamp.digest,
                                baseText: base, text: new, madeAt: madeAt, deviceText: new)
    }

    /// An entry appended to an Inbox file.
    public static func capture(id: UUID = UUID(), localPath: String, entry: String,
                               prologue: String?, madeAt: Date = Date()) -> VaultWriteRecord {
        VaultWriteRecord(id: id, path: VaultBridgePath.bridge(fromLocal: localPath),
                         kind: .capture, text: entry, madeAt: madeAt, prologue: prologue)
    }

    /// The one line that differs between two versions of a note, 1-based, or nil when none
    /// or several do.
    static func changedLine(from base: String, to new: String) -> Int? {
        let a = VaultCheckboxEdit.lines(base)
        let b = VaultCheckboxEdit.lines(new)
        guard a.count == b.count else { return nil }
        var found: Int?
        for index in a.indices where a[index] != b[index] {
            if found != nil { return nil }
            found = index + 1
        }
        return found
    }

    /// The version a conflict shows as this device's.
    public var deviceVersion: String { deviceText ?? text ?? "" }

    // MARK: The wire

    private struct Wire: Encodable {
        let id: String
        let path: String
        let kind: String
        let base_sha256: String?
        let base_text: String?
        let text: String?
        let line: Int?
        let checked: Bool?
        let made_at: String
        let force: Bool
        let prologue: String?
    }

    /// The JSON array `POST /jesse/vault/writes` takes.
    public static func wireBody(_ records: [VaultWriteRecord]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        let wire = records.map { record in
            Wire(id: record.id.uuidString.lowercased(), path: record.path,
                 kind: record.kind.rawValue, base_sha256: record.baseSHA256,
                 base_text: record.baseText, text: record.text, line: record.line,
                 checked: record.checked, made_at: formatter.string(from: record.madeAt),
                 force: record.force, prologue: record.prologue)
        }
        return try JSONEncoder().encode(wire)
    }
}

/// The device's paths and the bridge's are the same vault relative paths, except on a
/// device whose folder is the workspace ROOT rather than the vault: there every note sits
/// under `vault/`. The bridge's paths never do.
public enum VaultBridgePath {
    /// The bridge's path for a device relative one.
    public static func bridge(fromLocal path: String) -> String {
        var path = VaultWriteExemption.normalised(path)
        for prefix in ["vault/", "todo-list/"] where path.hasPrefix(prefix) {
            path.removeFirst(prefix.count)
        }
        return path
    }
}

// MARK: - What the bridge said

/// The bridge's answer for one record.
public enum VaultWriteAnswer: Equatable, Sendable {
    case applied(sha256: String?)
    case conflict(currentText: String, currentSHA256: String)
    case refused(reason: String)
}

/// What one send came back with.
public enum VaultWriteSendOutcome: Equatable, Sendable {
    /// Answers by record id. A record with no answer stays queued.
    case answered([UUID: VaultWriteAnswer])
    /// `404`: a bridge without the route.
    case routeMissing
    /// `503`: a turn is writing one of the notes. Everything stays, for the next flush.
    case busy
    /// Any other status, or a body that is not the contract. Everything stays.
    case failed(String)

    /// Read one response.
    public static func interpret(status: Int, body: Data) -> VaultWriteSendOutcome {
        switch status {
        case 404: return .routeMissing
        case 503: return .busy
        case 200..<300: break
        default:
            return .failed("HTTP \(status): \(String(decoding: body.prefix(200), as: UTF8.self))")
        }
        guard let list = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            return .failed("The bridge's answer was not a list.")
        }
        var answers: [UUID: VaultWriteAnswer] = [:]
        for item in list {
            guard let raw = item["id"] as? String, let id = UUID(uuidString: raw) else { continue }
            switch item["status"] as? String {
            case "applied":
                answers[id] = .applied(sha256: item["sha256"] as? String)
            case "conflict":
                answers[id] = .conflict(currentText: item["current_text"] as? String ?? "",
                                        currentSHA256: item["current_sha256"] as? String ?? "")
            case "refused":
                answers[id] = .refused(reason: item["reason"] as? String ?? "refused")
            default:
                continue
            }
        }
        return .answered(answers)
    }
}

/// Whatever can reach the bridge's write route, and the old strand tick route beside it.
/// A thrown error means "not reached": everything stays queued.
public protocol VaultWriteSending: StrandTickReporting {
    /// `POST /jesse/vault/writes` with `body`, answering the raw status and body.
    func sendVaultWrites(_ body: Data) async throws -> (status: Int, body: Data)
}

// MARK: - The outbox

/// Where one queued write stands.
public enum VaultWriteState: Codable, Equatable, Sendable {
    case queued
    /// The bridge could not place it. Held, with the Studio's version, until a person
    /// chooses "Keep mine" or "Take the Studio's".
    case conflicted(currentText: String, currentSHA256: String)
}

public struct VaultOutboxEntry: Codable, Equatable, Sendable, Identifiable {
    public var record: VaultWriteRecord
    public var state: VaultWriteState
    /// Reported through the old strand route to a bridge without the write route.
    public var strandTickSent: Bool
    public var id: UUID { record.id }

    public var isConflicted: Bool {
        if case .conflicted = state { return true }
        return false
    }

    /// The Studio's version, for a conflicted entry.
    public var studioVersion: String? {
        if case .conflicted(let text, _) = state { return text }
        return nil
    }
}

/// A record the bridge refused, kept until it has been shown once.
public struct VaultWriteRefusal: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let kind: VaultEditKind
    public let reason: String
}

/// The writes not yet answered, in order, persisted across launches.
public actor VaultWriteOutbox {

    /// The one every writer uses. Configured by each app shell with its bridge client.
    public static let shared = VaultWriteOutbox()

    /// Posted on the main queue after anything in the outbox changes, so a screen showing
    /// a conflict or a pending count can read it again.
    public static let didChange = Notification.Name("jesse.vault.writeOutbox.didChange")

    /// The key the strand tick outbox this replaced kept its queue under. Read once, moved
    /// into this outbox, and removed.
    public static let legacyTickKey = "jesse.strands.tickOutbox"

    /// How many records one request carries.
    public static let batchSize = 100

    /// How many delivered ids are remembered, for "delivered to the bridge".
    public static let deliveredCapacity = 400

    private struct Stored: Codable {
        var entries: [VaultOutboxEntry] = []
        var refusals: [VaultWriteRefusal] = []
        var delivered: [UUID] = []
        var legacyTicks: [StrandTickReport] = []

        init() {}

        /// Every key optional, so a file written by a build with fewer of them still loads
        /// rather than decoding as an empty queue.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = try c.decodeIfPresent([VaultOutboxEntry].self, forKey: .entries) ?? []
            refusals = try c.decodeIfPresent([VaultWriteRefusal].self, forKey: .refusals) ?? []
            delivered = try c.decodeIfPresent([UUID].self, forKey: .delivered) ?? []
            legacyTicks = try c.decodeIfPresent([StrandTickReport].self, forKey: .legacyTicks) ?? []
        }
    }

    public let url: URL
    private let legacySuite: String?
    private let migratesLegacy: Bool
    private var stored: Stored?
    private var makeSender: (@Sendable () async -> (any VaultWriteSending)?)?
    /// The last flush started. Each new one waits for it, so flushes form a chain.
    private var last: Task<Void, Never>?

    /// `fileURL` nil is Application Support, under a folder named for this bundle so a test
    /// runner can never share a real app's queue. `legacySuite` is the defaults suite the old
    /// strand tick queue lived in (nil: standard), read only when `migrateLegacy` is true.
    public init(fileURL: URL? = nil, legacySuite: String? = nil, migrateLegacy: Bool = true) {
        self.url = fileURL ?? Self.defaultURL()
        self.legacySuite = legacySuite
        self.migratesLegacy = migrateLegacy
    }

    static func defaultURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let owner = Bundle.main.bundleIdentifier ?? "unbundled"
        return base.appendingPathComponent("JesseVault", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("vault-write-outbox.json")
    }

    /// Hand the outbox a way to reach the bridge. A closure rather than a client because the
    /// shells rebuild their client from settings on every call.
    public func configure(sender: @escaping @Sendable () async -> (any VaultWriteSending)?) {
        makeSender = sender
    }

    // MARK: Reading

    /// Everything still waiting, oldest first.
    public var entries: [VaultOutboxEntry] { load().entries }

    /// What is waiting for one note, by the bridge's path.
    public func entries(forPath path: String) -> [VaultOutboxEntry] {
        let path = VaultBridgePath.bridge(fromLocal: path)
        return load().entries.filter { $0.record.path == path }
    }

    public var conflicts: [VaultOutboxEntry] { load().entries.filter(\.isConflicted) }

    /// Whether the bridge applied this record.
    public func isDelivered(_ id: UUID) -> Bool { load().delivered.contains(id) }

    /// The delivered ids among `ids`.
    public func delivered(among ids: [UUID]) -> Set<UUID> {
        Set(load().delivered).intersection(ids)
    }

    /// The refusals not yet shown, which are now shown: each is returned once.
    public func takeRefusals() throws -> [VaultWriteRefusal] {
        var state = load()
        let out = state.refusals
        guard !out.isEmpty else { return [] }
        state.refusals = []
        try store(state)
        return out
    }

    // MARK: Writing

    /// Keep `record`. Throws when it cannot be persisted, and the writer then refuses the
    /// write: a write the Studio will never hear about is the thing this type exists to end.
    ///
    /// Idempotent by id: a record already waiting is not queued twice.
    public func enqueue(_ record: VaultWriteRecord) throws {
        var state = load()
        guard !state.entries.contains(where: { $0.id == record.id }) else { return }
        state.entries.append(VaultOutboxEntry(record: record, state: .queued,
                                              strandTickSent: false))
        try store(state)
    }

    /// Take back a record whose local write then failed. It was never a write.
    public func remove(id: UUID) {
        var state = load()
        state.entries.removeAll { $0.id == id }
        try? store(state)
    }

    /// "Keep mine": send the device's version again, over the Studio's current one.
    ///
    /// The SAME id, so the bridge still applies it once; the returned current hash as the
    /// base; and `force`. A tick is sent as the whole note it left behind, because the line
    /// alone is exactly what could not be placed.
    public func keepMine(id: UUID) async {
        var state = load()
        guard let at = state.entries.firstIndex(where: { $0.id == id }),
              case .conflicted(_, let currentSHA) = state.entries[at].state else { return }
        var record = state.entries[at].record
        if record.kind != .edit {
            record.kind = .edit
            record.text = record.deviceVersion
            record.line = nil
            record.checked = nil
        }
        record.baseSHA256 = currentSHA
        record.force = true
        state.entries[at] = VaultOutboxEntry(record: record, state: .queued,
                                             strandTickSent: state.entries[at].strandTickSent)
        try? store(state)
        await flush()
    }

    /// "Take the Studio's": the device's version is dropped. The reader then shows the
    /// Studio's copy; nothing is written into the Obsidian folder, which Obsidian itself
    /// brings up to date.
    public func takeStudios(id: UUID) {
        remove(id: id)
    }

    // MARK: Sending

    /// Send what is waiting, in order, until nothing is left that the bridge can answer.
    ///
    /// A CHAIN, not a flag: each flush waits for the one before it and then drains once, so
    /// two writes in a row can never race each other to the bridge or be sent twice.
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
        guard let sender = await makeSender?() else { return }
        if !(await drainLegacy(sender)) { return }
        while true {
            let batch = load().entries.filter { $0.state == .queued }
                .prefix(Self.batchSize).map(\.record)
            guard !batch.isEmpty, let body = try? VaultWriteRecord.wireBody(Array(batch)) else {
                return
            }
            let outcome: VaultWriteSendOutcome
            do {
                let (status, data) = try await sender.sendVaultWrites(body)
                outcome = VaultWriteSendOutcome.interpret(status: status, body: data)
            } catch {
                return
            }
            switch outcome {
            case .answered(let answers):
                apply(answers)
                // A batch the bridge answered none of would loop for ever.
                if !batch.contains(where: { answers[$0.id] != nil }) { return }
            case .routeMissing:
                await reportStrandTicksTheOldWay(sender)
                return
            case .busy, .failed:
                return
            }
        }
    }

    private func apply(_ answers: [UUID: VaultWriteAnswer]) {
        var state = load()
        var kept: [VaultOutboxEntry] = []
        for entry in state.entries {
            switch answers[entry.id] {
            case .applied?:
                state.delivered.append(entry.id)
            case .conflict(let text, let sha)?:
                var entry = entry
                entry.state = .conflicted(currentText: text, currentSHA256: sha)
                kept.append(entry)
            case .refused(let reason)?:
                state.refusals.append(VaultWriteRefusal(id: entry.id, path: entry.record.path,
                                                        kind: entry.record.kind,
                                                        reason: reason))
            case nil:
                kept.append(entry)
            }
        }
        state.entries = kept
        if state.delivered.count > Self.deliveredCapacity {
            state.delivered.removeFirst(state.delivered.count - Self.deliveredCapacity)
        }
        try? store(state)
    }

    /// An older bridge: every strand tick not yet reported goes to its strand route, and
    /// everything stays queued for a bridge that has the write route.
    private func reportStrandTicksTheOldWay(_ sender: any VaultWriteSending) async {
        for entry in load().entries where !entry.strandTickSent {
            guard let tick = entry.record.strandTick else { continue }
            do {
                _ = try await sender.reportStrandTick(tick)
            } catch {
                return
            }
            var state = load()
            if let at = state.entries.firstIndex(where: { $0.id == entry.id }) {
                state.entries[at].strandTickSent = true
                try? store(state)
            }
        }
    }

    /// The old strand tick queue, moved in on first load, goes first and the old way: those
    /// ticks were made before this outbox existed and carry no note path or line.
    private func drainLegacy(_ sender: any VaultWriteSending) async -> Bool {
        while let next = load().legacyTicks.first {
            do {
                _ = try await sender.reportStrandTick(next)
            } catch {
                return false
            }
            var state = load()
            state.legacyTicks.removeFirst()
            try? store(state)
        }
        return true
    }

    // MARK: The file

    private func load() -> Stored {
        if let stored { return stored }
        var loaded = Stored()
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.outbox.decode(Stored.self, from: data) {
            loaded = decoded
        }
        if migratesLegacy {
            let defaults = legacySuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
            if let data = defaults.data(forKey: Self.legacyTickKey),
               let ticks = try? JSONDecoder().decode([StrandTickReport].self, from: data),
               !ticks.isEmpty {
                loaded.legacyTicks.append(contentsOf: ticks)
                if (try? write(loaded)) != nil {
                    defaults.removeObject(forKey: Self.legacyTickKey)
                }
            }
        }
        stored = loaded
        return loaded
    }

    private func store(_ state: Stored) throws {
        try write(state)
        stored = state
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private func write(_ state: Stored) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder.outbox.encode(state).write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static var outbox: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var outbox: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
