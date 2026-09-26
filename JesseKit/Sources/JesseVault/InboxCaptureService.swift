import Foundation
import Observation

// THE CAPTURE, END TO END, IN ONE PLACE THE APPS CALL.
//
// Decide, write, log, verify. The two composers contribute a button and the reader
// contributes a menu item; everything they would otherwise each have to get right — when
// the offer is even made, which file is written, what the badge says, what is recorded,
// what happens to a capture whose line has gone — is here, once.
//
// NOTHING ON THIS PATH TOUCHES THE NETWORK, NOTHING ASKS A MODEL, AND NOTHING QUEUES.
// A capture is a coordinated append to one file under `Inbox/` and a row in a JSON log.
// That is the complete set of side effects, and it is the reason a capture is worth more
// than a queued message: the vault has it before the button finishes animating.

/// Whether the composer offers to capture instead of queueing.
public enum InboxCaptureOffer: Equatable, Sendable {
    /// The composer looks exactly as it did before this feature existed.
    case hidden
    /// Capture to Inbox is offered, beside the ordinary send.
    case offered

    public var isOffered: Bool { self == .offered }
}

/// The offer, as a pure rule.
public enum InboxCaptureRouting {

    /// Whether this composer offers a capture.
    ///
    /// `.unreachable`, not merely "not reachable": `.unknown` is a cold launch's pre-probe
    /// state, and offering a local capture there would put a second send control in front
    /// of someone whose bridge is perfectly fine and who would reasonably read the two as
    /// alternatives.
    ///
    /// The ordinary send is NEVER removed. This adds a destination; it does not replace
    /// one, because plenty of offline messages really do need the agent and belong in the
    /// queue.
    public static func offer(reachability: BridgeReachabilityState,
                             hasVaultFolder: Bool) -> InboxCaptureOffer {
        guard reachability == .unreachable else { return .hidden }
        guard hasVaultFolder else { return .hidden }
        return .offered
    }
}

/// A capture that failed, with something a person can read.
public enum InboxCaptureFailure: Error, Equatable, CustomStringConvertible {
    case noFolder
    case refused(String)
    case failed(String)

    public var description: String {
        switch self {
        case .noFolder:
            return "No vault folder is held on this device — pick it in Settings."
        case .refused(let why): return why
        case .failed(let why): return "Couldn't write to the vault: \(why)"
        }
    }
}

/// Write one capture, log it, and later say whether it is still there.
@MainActor
public final class InboxCaptureService {
    /// See the GOTCHA in this target's `Package.swift` comment: an explicitly `@MainActor`
    /// class's synthesized deinit is MainActor-isolated, and a test host releasing this off
    /// the main actor would route through the isolated-deinit executor hop, which aborts.
    nonisolated deinit {}

    /// The app's one service.
    public static let shared = InboxCaptureService()

    private let source: VaultIndexSource
    private let log: OfflineWriteLog
    private let platform: InboxCapturePlatform
    private let deviceName: @Sendable () -> String
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    /// Where every capture is ALSO queued for the Studio. The capture is written into the
    /// device's own Inbox folder, which on the phone reaches the Studio only if Obsidian iOS
    /// syncs a file another app changed, and it does not. Nil only in a test not about it.
    private let outbox: VaultWriteOutbox?

    public init(source: VaultIndexSource = .shared,
                log: OfflineWriteLog = .shared,
                platform: InboxCapturePlatform = .current,
                deviceName: @escaping @Sendable () -> String = { VaultDiagnosticsModel.deviceName() },
                now: @escaping @Sendable () -> Date = { Date() },
                timeZone: @escaping @Sendable () -> TimeZone = { .current },
                outbox: VaultWriteOutbox? = .shared) {
        self.outbox = outbox
        self.source = source
        self.log = log
        self.platform = platform
        self.deviceName = deviceName
        self.now = now
        self.timeZone = timeZone
    }

    /// Whether this device holds a vault folder. Resolves a security-scoped bookmark, so
    /// it is not free and is only ever asked once reachability has already said it matters.
    public var hasVaultFolder: Bool { source.root != nil }

    /// The offer for one composer state.
    ///
    /// REACHABILITY FIRST, and on its own, for the reason `OfflineAnswerService.route`
    /// short-circuits: Swift evaluates every argument before the pure rule can decide, and
    /// the overwhelmingly common case is a reachable bridge that must not pay for a
    /// bookmark resolution to learn it has nothing to show.
    public func offer(reachability: BridgeReachabilityState) -> InboxCaptureOffer {
        guard reachability == .unreachable else { return .hidden }
        return InboxCaptureRouting.offer(reachability: reachability,
                                         hasVaultFolder: hasVaultFolder)
    }

    /// The rows the diagnostics screen shows, newest first.
    public var recent: [OfflineWriteRecord] { log.recent }

    /// Capture one thought.
    ///
    /// The append happens OFF the main actor. It is a coordinated write to a file provider's
    /// folder, which can block for as long as the provider wants, and the composer that
    /// called this is on screen.
    public func capture(_ text: String, about: String? = nil) async -> Result<InboxCaptureWrite, InboxCaptureFailure> {
        let folder = source.vaultFolder
        let platform = self.platform
        let device = deviceName()
        let stamp = now()
        let zone = timeZone()
        guard hasVaultFolder else { return .failure(.noFolder) }

        // QUEUED FOR THE STUDIO FIRST, with the exact entry and file the append below will
        // write (the same pure functions `InboxCapture.capture` calls), and taken back if the
        // append fails. A capture that cannot be queued is not written.
        let entry: String
        do {
            entry = try InboxCapture.entry(text: text, about: about, device: device,
                                           now: stamp, timeZone: zone)
        } catch {
            return .failure(Self.failure(error))
        }
        let record = VaultWriteRecord.capture(
            localPath: InboxCapture.relativePath(platform: platform, now: stamp, timeZone: zone),
            entry: entry,
            prologue: InboxCapture.fileHeader(platform: platform, now: stamp, timeZone: zone),
            madeAt: stamp)
        if let failure = await queue(record) { return .failure(failure) }

        let outcome: Result<InboxCaptureWrite, Error> = await Task.detached {
            do {
                return .success(try folder.withAccess { root in
                    try InboxCapture(file: VaultFile(root: root), platform: platform)
                        .capture(text: text, about: about, device: device,
                                 now: stamp, timeZone: zone)
                })
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let write):
            log.record(OfflineWriteRecord(
                id: record.id,
                written: stamp, file: write.relativePath, bytes: write.bytesAppended,
                checksum: write.checksum, text: write.entry,
                about: InboxCapture.normalizedAbout(about), status: .written))
            send()
            return .success(write)
        case .failure(let error):
            await outbox?.remove(id: record.id)
            return .failure(Self.failure(error))
        }
    }

    /// Queue one record, or say why it could not be.
    private func queue(_ record: VaultWriteRecord) async -> InboxCaptureFailure? {
        guard let outbox else { return nil }
        do {
            try await outbox.enqueue(record)
            return nil
        } catch {
            return .failed("It couldn't be queued for the Studio, so it wasn't written: \(error.localizedDescription)")
        }
    }

    /// Send what is queued, without waiting: the composer that called this is on screen.
    private func send() {
        guard let outbox else { return }
        Task { await outbox.flush() }
    }

    /// Write a logged capture's own entry back into its own file.
    ///
    /// Only ever from a person pressing Re-capture. It appends the original entry — same
    /// timestamp, same checksum — so the verification pass can confirm it afterwards, and
    /// it does NOT add a second log row: this is the same capture, being made good.
    public func recapture(_ record: OfflineWriteRecord) async -> Result<InboxCaptureWrite, InboxCaptureFailure> {
        let folder = source.vaultFolder
        let platform = self.platform
        let stamp = now()
        let zone = timeZone()
        guard hasVaultFolder else { return .failure(.noFolder) }

        // The SAME id as the original capture: a bridge that already has it answers
        // `applied` and appends nothing, and one that does not appends it once.
        let queued = VaultWriteRecord.capture(
            id: record.id, localPath: record.file, entry: record.text,
            prologue: InboxCapture.fileHeader(forRelativePath: record.file, fallbackNow: stamp,
                                              timeZone: zone),
            madeAt: record.written)
        if let failure = await queue(queued) { return .failure(failure) }

        let outcome: Result<InboxCaptureWrite, Error> = await Task.detached {
            do {
                return .success(try folder.withAccess { root in
                    try InboxCapture(file: VaultFile(root: root), platform: platform)
                        .rewrite(entry: record.text, relativePath: record.file,
                                 now: stamp, timeZone: zone)
                })
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let write):
            log.apply(statuses: [record.id: .written])
            send()
            return .success(write)
        case .failure(let error):
            // Left queued: the capture WAS made, on this device, and the Studio should have
            // it whether or not the folder takes it back.
            return .failure(Self.failure(error))
        }
    }

    /// Re-read the capture files the log names and record what is still in them.
    ///
    /// Called on activation, which is exactly when the local copy may have been resynced
    /// behind the app's back — the same moment the index reindexes. It reads only the files
    /// the log names, never the vault, and it NEVER re-appends: a missing line becomes a row
    /// a person is shown, and nothing else.
    ///
    /// A device with no folder is left alone entirely. Marking everything "not found"
    /// because a bookmark went stale would turn a Settings problem into a page of alarms.
    @discardableResult
    public func verifyRecent() async -> [UUID: OfflineWriteStatus] {
        let records = log.recent
        guard !records.isEmpty, hasVaultFolder else { return [:] }
        let folder = source.vaultFolder
        let statuses: [UUID: OfflineWriteStatus] = await Task.detached {
            (try? folder.withAccess { root in
                let file = VaultFile(root: root)
                return OfflineWriteVerifier.statuses(for: records) {
                    try file.read(relativePath: $0)
                }
            }) ?? [:]
        }.value
        log.apply(statuses: statuses)
        return statuses
    }

    /// One error, in the words a composer shows.
    nonisolated static func failure(_ error: Error) -> InboxCaptureFailure {
        if let capture = error as? InboxCaptureError { return .refused(capture.description) }
        if let file = error as? VaultFileError { return .failed(file.description) }
        if let folder = error as? VaultFolderError { return .failed(folder.description) }
        return .failed(error.localizedDescription)
    }
}

/// The one-field sheet the reader opens.
///
/// A model of its own rather than `@State` in the view, for the reason every other model in
/// this target is one: "an empty field cannot be saved", "a refusal leaves the text where
/// it was" and "a success reports which file it went to" are three behaviours a unit test
/// states directly, and none of them needs a sheet to be on screen.
@MainActor
@Observable
public final class VaultCaptureModel {
    /// See the GOTCHA in this target's `Package.swift` comment.
    nonisolated deinit {}

    /// The note this capture is about, when it is about one.
    public let about: String?
    public var text: String = ""
    public private(set) var busy = false
    public private(set) var error: String?
    /// Set once the capture has landed. The sheet watches it and dismisses.
    public private(set) var written: InboxCaptureWrite?

    private let service: InboxCaptureService

    public init(about: String? = nil, service: InboxCaptureService = .shared) {
        self.about = about
        self.service = service
    }

    /// Whether Save does anything. Mirrors the refusal inside `InboxCapture.entry` rather
    /// than duplicating its rule: the button is dead for empty text, and oversize text is
    /// refused with the message that says how long it actually is.
    public var canSave: Bool {
        !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the sheet says above the field.
    public var subtitle: String {
        guard let path = InboxCapture.normalizedAbout(about) else {
            return "Goes straight into the vault's Inbox on this device, and syncs when this device next can."
        }
        return "Filed against \(path) in the vault's Inbox on this device."
    }

    public func save() async {
        guard canSave else { return }
        busy = true
        error = nil
        defer { busy = false }
        switch await service.capture(text, about: about) {
        case .success(let write):
            written = write
        case .failure(let failure):
            // The text stays exactly where it was. A capture is not something to lose to an
            // error message.
            error = failure.description
        }
    }
}
