import Foundation
import Observation

// KEEPING THE INDEX HONEST, WITHOUT EVER BEING IN THE WAY.
//
// Indexing a vault is seconds of work at best and tens of seconds the first time, so the
// rules here are all about WHEN, not how:
//
//   * NEVER ON THE MAIN ACTOR. Every walk, read and write happens in one detached task.
//     What runs on the main actor is the progress number and the final report.
//   * ONE AT A TIME, AND COALESCED. A second request while a run is in flight sets a flag
//     rather than starting a second walk; the flag is honoured once the first run ends. Two
//     concurrent reindexes of the same database would serialize on SQLite's own lock
//     anyway, having already paid twice for the walk.
//   * DEBOUNCED TO ONCE PER 30 SECONDS. The trigger is app activation, and on a phone
//     activation happens constantly — every notification glance, every app switch. A
//     vault does not change that fast.
//   * NEVER ON A TIMER. Nothing here wakes up on its own, and nothing runs while the app
//     is in the background. An index is refreshed because somebody came back to the app or
//     pressed the button, not because a clock fired.
//
// The scan-then-diff shape is what makes all of that affordable: `VaultScanner` reports
// every file's modification time and size for about a second of walking, and
// `VaultIndex.reindex` reads only the files whose pair changed. The steady-state cost of a
// reindex is therefore the walk, not the corpus.

/// Where an index comes from. One per process in the app; one per temporary directory in a
/// test.
///
/// It caches ONE open connection per folder and hands the same one to the search model and
/// to the indexer, deliberately. Two connections would need WAL's reader/writer overlap to
/// be right; one connection with a lock around each statement gives a search a wait of one
/// file's writes at worst, and no chance at all of "database is locked" reaching a screen.
public final class VaultIndexSource: @unchecked Sendable {

    /// The app's one source.
    public static let shared = VaultIndexSource()

    private let folder: VaultFolder
    /// Where the database directory is rooted. Nil means Application Support, which is
    /// what the app uses; a test passes its own temporary directory.
    private let container: URL?
    private let lock = NSLock()
    private var cached: (root: URL, index: VaultIndex)?

    public init(folder: VaultFolder = VaultFolder(), container: URL? = nil) {
        self.folder = folder
        self.container = container
    }

    /// The folder this device holds, or nil when there is none to hold.
    public var root: URL? { folder.resolve().url }

    public var folderStatus: VaultFolderStatus { folder.resolve() }

    /// The vault folder value itself, for the callers that need a coordinated read rather
    /// than the index (the reader, and the offline day-file fallback).
    public var vaultFolder: VaultFolder { folder }

    /// The index for the folder currently held, opened on first use.
    ///
    /// Returns nil — never throws — when no folder is held, because "no folder picked" is
    /// an ordinary state of this device and not a failure. A real failure (no FTS5, an
    /// unwritable container) throws.
    public func index() throws -> VaultIndex? {
        guard let root else { return nil }
        return try lock.withLock {
            if let cached, cached.root == root { return cached.index }
            let url = VaultIndex.databaseURL(forRoot: root, in: container)
            let opened = try VaultIndex(url: url)
            cached = (root, opened)
            return opened
        }
    }

    /// Forget the open connection — what a folder change means. The next call reopens
    /// against whatever folder is held then.
    public func close() {
        lock.withLock { cached = nil }
    }
}

/// A stop signal that crosses into a detached task.
///
/// `Task.detached` deliberately inherits NOTHING, cancellation included, so cancelling the
/// task that spawned the walk would leave the walk running. This one flag is the whole
/// mechanism, and it is read at a file boundary so a stop never leaves a half-written row.
final class VaultCancelSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}

/// The reindexing state a screen can watch, and the three ways to ask for one.
@MainActor
@Observable
public final class VaultIndexer {
    /// See the GOTCHA in this target's `Package.swift` comment: an explicitly `@MainActor`
    /// class's synthesized deinit is MainActor-isolated, and a test host releasing this off
    /// the main actor would route through the isolated-deinit executor hop, which aborts.
    nonisolated deinit {}

    public private(set) var isIndexing = false
    /// 0 to 1 while a run is in flight. Reported per percent rather than per file: a
    /// progress bar cannot show 7,600 steps and hopping to the main actor 7,600 times is
    /// the kind of cost that shows up as a stutter.
    public private(set) var progress: Double = 0
    public private(set) var lastReport: VaultReindexReport?
    public private(set) var lastError: String?
    /// What the index currently holds. Refreshed after every run.
    public private(set) var counts = VaultIndexCounts()

    /// When the last run FINISHED, which is what the debounce is measured from. Measuring
    /// from the start would let a 40 second first index be followed immediately by another.
    private var lastFinishedAt: Date?
    private var task: Task<Void, Never>?
    /// The stop signal for the run in flight.
    private var signal: VaultCancelSignal?
    /// A request that arrived while a run was in flight. Honoured once, after it ends.
    private var coalesced = false
    private let source: VaultIndexSource

    public init(source: VaultIndexSource = .shared) {
        self.source = source
    }

    /// The app-activation trigger: reindex unless one ran within `debounce` seconds.
    ///
    /// Fire and forget — it returns immediately, whether or not it started anything.
    public func reindexIfDue(debounce: TimeInterval = 30) {
        if let lastFinishedAt, Date().timeIntervalSince(lastFinishedAt) < debounce,
           !isIndexing {
            return
        }
        start()
    }

    /// The button: reindex now, debounce ignored, and await the run so a screen can show
    /// the result.
    public func reindexNow() async {
        start(force: true)
        await task?.value
    }

    /// Bring ONE file's rows into line, debounce ignored, without walking the vault.
    ///
    /// What the app calls after it writes a note. It is not `reindexNow`: a whole-vault
    /// reindex after every tick would be a second of walking per tap, and the debounce
    /// that exists to prevent that would also mean the tap's own words are not findable
    /// for thirty seconds. One file is milliseconds and is always right.
    ///
    /// Deliberately cannot throw and does not touch `lastError`. It runs AFTER a write
    /// that has already landed on disk, and a failure here means "the search index is a
    /// little behind", which the next activation fixes on its own — not something to put
    /// on a screen next to an edit that succeeded. Returns whether it worked, for the test.
    @discardableResult
    public func reindex(path: String) async -> Bool {
        let source = self.source
        return await Task.detached {
            guard let index = try? source.index() else { return false }
            let done = try? source.vaultFolder.withAccess { root -> Bool in
                do {
                    try index.reindex(file: path, root: root)
                    return true
                } catch {
                    return false
                }
            }
            return done ?? false
        }.value
    }

    /// Throw the index away and build it again from nothing.
    public func rebuild() async {
        guard !isIndexing else { return }
        isIndexing = true
        lastError = nil
        progress = 0
        let source = self.source
        let outcome: Result<Void, Error> = await Task.detached {
            do {
                guard let index = try source.index() else { return .success(()) }
                try index.rebuild()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        isIndexing = false
        if case .failure(let error) = outcome {
            lastError = Self.describe(error)
        }
        lastReport = nil
        lastFinishedAt = nil
        refreshCounts()
        await reindexNow()
    }

    /// Read the counts without indexing anything — what the diagnostics screen shows on
    /// appear.
    public func refreshCounts() {
        counts = (try? source.index())?.counts() ?? VaultIndexCounts()
    }

    /// Stop the run in flight at the next file boundary. Everything committed so far
    /// stands, and the next run picks up from there.
    public func cancel() {
        coalesced = false
        signal?.stop()
        task?.cancel()
    }

    // MARK: - The one run

    private func start(force: Bool = false) {
        if isIndexing {
            // A request during a run is remembered, not dropped: the file that prompted it
            // may have changed after the walk had already passed it.
            coalesced = true
            return
        }
        guard source.root != nil else { return }
        if !force, let lastFinishedAt, Date().timeIntervalSince(lastFinishedAt) < 1 { return }
        isIndexing = true
        progress = 0
        lastError = nil
        let signal = VaultCancelSignal()
        self.signal = signal
        task = Task { [weak self] in
            await self?.run(signal: signal)
        }
    }

    private func run(signal: VaultCancelSignal) async {
        let source = self.source
        // The progress callback hops to the main actor, and is throttled to whole percents
        // by the detached side so the hop happens 100 times rather than 7,600.
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in self?.progress = value }
        }
        let outcome: Result<VaultReindexReport, Error> = await Task.detached {
            do {
                guard let index = try source.index() else {
                    return .success(VaultReindexReport())
                }
                let folder = source.vaultFolder
                var lastPercent = -1
                return .success(try folder.withAccess { root in
                    let scan = VaultScanner().scan(root: root)
                    let file = VaultFile(root: root)
                    return try index.reindex(
                        scan: scan,
                        read: { try file.read(relativePath: $0) },
                        progress: { value in
                            let percent = Int(value * 100)
                            guard percent != lastPercent else { return }
                            lastPercent = percent
                            report(value)
                        },
                        isCancelled: { signal.isStopped })
                })
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let done):
            lastReport = done
        case .failure(let error):
            lastError = Self.describe(error)
        }
        isIndexing = false
        progress = 1
        self.signal = nil
        lastFinishedAt = Date()
        refreshCounts()
        if coalesced {
            coalesced = false
            start(force: true)
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let index = error as? VaultIndexError { return index.description }
        if let file = error as? VaultFileError { return file.description }
        if let folder = error as? VaultFolderError { return folder.description }
        return error.localizedDescription
    }
}
