import Foundation

// Where a recording lives while it is being turned into text, and — much more
// importantly — the rules that get it deleted again.
//
// THE POLICY, stated once: Jesse never keeps the audio. Voice Memos (or Files, or
// whatever recorded it) holds the authoritative copy; a second copy here would be a
// private recording duplicated into an app that has no use for it once the words are
// out. What persists in a conversation is the transcript. So every copy this file
// creates is a WORKING copy with a defined death, on every exit path including failure,
// cancellation, and the process being killed mid-run.
//
// There are two of them because the two entry points have genuinely different lifetimes:
//
//   * `RecordingWorkingCopy` — the composer's own file picker. The copy exists inside one
//     transcription and is deleted when it ends. Nothing is ever legitimately in flight
//     at launch, so launch purges the whole directory; that is the crash recovery.
//   * `RecordingHandoffStore` — the share extension's app-group inbox. This copy MUST
//     outlive the process that made it (the extension is killed the moment its sheet is
//     dismissed) and be found by the app later, so it cannot be purged wholesale. It is
//     swept instead, by rules that distinguish "waiting to be picked up" from "abandoned".

/// A recording the share extension took custody of, waiting for the app to transcribe it.
///
/// It records what the app will otherwise have lost by the time it runs: the file's real
/// name (the working copy is named after a UUID), how long it is (probed in the
/// extension, where the file is definitely readable), and when it arrived. The
/// security-scoped URL the extension received is deliberately NOT here — it is not valid
/// in the app's process, and storing it would be a reference to a file the app cannot
/// open.
public struct PendingRecording: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The name to show the user and stamp into the message header.
    public let originalName: String
    /// Seconds, when the extension could read it. Nil is not an error — the app probes
    /// its own copy anyway; this only saves it doing so before it has decided to.
    public let durationSeconds: Double?
    public let arrivedAt: Date
    /// The working copy's extension, so its filename can be reconstructed.
    public let fileExtension: String

    public init(id: UUID = UUID(),
                originalName: String,
                durationSeconds: Double?,
                arrivedAt: Date,
                fileExtension: String) {
        self.id = id
        self.originalName = originalName
        self.durationSeconds = durationSeconds
        self.arrivedAt = arrivedAt
        self.fileExtension = fileExtension
    }

    /// The audio file's name inside the inbox.
    public var audioFileName: String {
        fileExtension.isEmpty ? id.uuidString : "\(id.uuidString).\(fileExtension)"
    }

    /// The manifest's name inside the inbox.
    public var manifestFileName: String { "\(id.uuidString).json" }
}

/// The app-group inbox: written by the share extension, drained by the app.
///
/// Sendable by holding nothing but a URL. `FileManager.default` is used internally
/// rather than stored, because `FileManager` is not `Sendable` and this type is handed
/// between actors freely.
public struct RecordingHandoffStore: Sendable {
    /// The app group both the app and the share extension are members of. It exists for
    /// this feature and nothing else: the extension cannot hand the app a file any other
    /// way, because the URL it is given is scoped to its own process.
    public static let appGroupIdentifier = "group.com.tag1.Jesse"

    /// A manifest and its audio are abandoned rather than pending once they are this
    /// old. Twenty-four hours is far longer than the gap between sharing something and
    /// opening the app, and deleting after it is the "never keep the audio" rule
    /// applying to the case where the user changed their mind — the recording is still
    /// in Voice Memos, which is where it belongs.
    public static let maxAge: TimeInterval = 24 * 60 * 60

    /// How long an audio file with no manifest is left alone before it is judged an
    /// orphan. It covers the one legitimate window in which that state is normal: the
    /// extension has finished copying and has not yet written the manifest. Without it,
    /// an app foregrounded at exactly the wrong moment would delete a share that was
    /// about to become valid.
    public static let orphanGrace: TimeInterval = 5 * 60

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The shared inbox, or nil when the app group is not provisioned (which is a
    /// signing/entitlement problem, and one the caller must report rather than silently
    /// lose a recording over).
    public static func shared(appGroup: String = RecordingHandoffStore.appGroupIdentifier) -> RecordingHandoffStore? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return RecordingHandoffStore(directory: container.appendingPathComponent("AudioInbox",
                                                                                isDirectory: true))
    }

    /// Take custody of `source` by COPYING it in, then record what it was.
    ///
    /// Copying and not referencing is the whole point: the extension's URL is
    /// security-scoped to a process that is about to be killed. The order — copy to a
    /// `.partial` name, move it into place, and only then write the manifest — is what
    /// makes a crash at any instant recoverable: a `.partial` is unfinished, an audio
    /// file with no manifest is a failed hand-off, and a manifest that exists is a
    /// promise that the audio beside it is complete.
    @discardableResult
    public func stage(copying source: URL,
                      originalName: String,
                      durationSeconds: Double?,
                      id: UUID = UUID(),
                      arrivedAt: Date = Date()) throws -> PendingRecording {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = source.pathExtension.isEmpty
            ? URL(fileURLWithPath: originalName).pathExtension
            : source.pathExtension
        let record = PendingRecording(id: id,
                                      originalName: originalName,
                                      durationSeconds: durationSeconds,
                                      arrivedAt: arrivedAt,
                                      fileExtension: ext)

        let staged = directory.appendingPathComponent(record.audioFileName)
        let partial = staged.appendingPathExtension("partial")
        try? manager.removeItem(at: partial)
        try? manager.removeItem(at: staged)
        try manager.copyItem(at: source, to: partial)
        try manager.moveItem(at: partial, to: staged)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(record).write(to: manifestURL(for: record), options: .atomic)
        } catch {
            // A manifest that could not be written means the app can never find this
            // audio, so it is litter rather than a hand-off. Take it back out now.
            try? manager.removeItem(at: staged)
            throw error
        }
        return record
    }

    /// Everything waiting to be transcribed, oldest first.
    ///
    /// A manifest whose audio has gone is skipped rather than returned: handing the app
    /// a record it cannot open would turn a tidy-up problem into a user-visible failure.
    public func pending() -> [PendingRecording] {
        let manager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> PendingRecording? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                      let record = try? decoder.decode(PendingRecording.self, from: data),
                      manager.fileExists(atPath: audioURL(for: record).path) else { return nil }
                return record
            }
            .sorted { $0.arrivedAt < $1.arrivedAt }
    }

    public func audioURL(for record: PendingRecording) -> URL {
        directory.appendingPathComponent(record.audioFileName)
    }

    public func manifestURL(for record: PendingRecording) -> URL {
        directory.appendingPathComponent(record.manifestFileName)
    }

    /// Delete a hand-off and its audio. Called the moment a transcript exists, and on
    /// every failure path too — a recording that could not be transcribed is not a
    /// recording worth storing.
    public func discard(_ record: PendingRecording) {
        let manager = FileManager.default
        try? manager.removeItem(at: audioURL(for: record))
        try? manager.removeItem(at: manifestURL(for: record))
    }

    /// Delete what is abandoned rather than pending. Run at launch and at foreground.
    ///
    /// Three rules, each naming a state a crash can leave behind:
    ///   * a manifest with no audio — the audio was deleted, the manifest was not;
    ///   * a file with no manifest, older than `orphanGrace` — a copy that never
    ///     finished, or one whose manifest write failed;
    ///   * a complete pair older than `maxAge` — shared, never opened, and now stale.
    public func sweep(now: Date = Date(),
                      maxAge: TimeInterval = RecordingHandoffStore.maxAge,
                      orphanGrace: TimeInterval = RecordingHandoffStore.orphanGrace) {
        let manager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []

        var claimed = Set<String>()
        for name in names where name.hasSuffix(".json") {
            let manifest = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: manifest),
                  let record = try? decoder.decode(PendingRecording.self, from: data) else {
                try? manager.removeItem(at: manifest)
                continue
            }
            let audio = audioURL(for: record)
            guard manager.fileExists(atPath: audio.path) else {
                try? manager.removeItem(at: manifest)
                continue
            }
            if now.timeIntervalSince(record.arrivedAt) > maxAge {
                discard(record)
                continue
            }
            claimed.insert(record.audioFileName)
        }

        for name in names where !name.hasSuffix(".json") && !claimed.contains(name) {
            let file = directory.appendingPathComponent(name)
            let modified = (try? manager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
                ?? nil
            if let modified, now.timeIntervalSince(modified) <= orphanGrace { continue }
            try? manager.removeItem(at: file)
        }
    }
}

/// The composer's own scratch directory for a picked file.
///
/// `fileImporter` hands back a security-scoped URL into somebody else's container, and
/// the speech engine needs a file it can read for minutes without that scope being
/// juggled. So the bytes are copied here, transcribed, and deleted — and because nothing
/// is ever legitimately mid-transcription at launch, launch deletes the lot. That single
/// rule is the whole crash story for this path: there is no state to reconcile, because
/// anything present is by definition abandoned.
public struct RecordingWorkingCopy: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The app's own working directory, under Caches (never backed up, and the system
    /// may reclaim it — both correct for a file we are actively trying to delete).
    public static func standard() -> RecordingWorkingCopy {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return RecordingWorkingCopy(directory: base.appendingPathComponent("AudioTranscription",
                                                                           isDirectory: true))
    }

    /// Copy `source` in and return the working URL. The caller must `remove` it on every
    /// exit path.
    public func adopt(copying source: URL, id: UUID = UUID()) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension
        let name = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let destination = directory.appendingPathComponent(name)
        try? manager.removeItem(at: destination)
        try manager.copyItem(at: source, to: destination)
        return destination
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Delete everything here. Safe only at launch, where nothing is in flight — which
    /// is exactly when it is called, and why it needs no age or ownership rules.
    public func purge() {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
