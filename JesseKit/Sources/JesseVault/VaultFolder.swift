import Foundation

// The BOOKMARK STORE: the one place that knows how this device holds on to the
// folder the user picked.
//
// The app has never had this. Everything vault-shaped went through the bridge
// (`GET /jesse/today`, the detail endpoint, the chat turns), so with the bridge
// unreachable not one note could be opened, even though Obsidian keeps a complete
// synced copy of the same vault on this very device. A folder picked in a document
// picker is reachable for exactly as long as that picker's URL lives unless a
// SECURITY-SCOPED BOOKMARK is taken, which is what this file takes and persists.
//
// Two platform differences, both load-bearing:
//
//   * macOS needs `.withSecurityScope` when CREATING the bookmark and
//     `.withSecurityScope` when RESOLVING it. iOS has no such option for a
//     document-picker URL — passing one there produces a bookmark that does not
//     resolve — so iOS uses the default options on both sides.
//   * `startAccessingSecurityScopedResource()` is REFERENCE COUNTED. Every start
//     must be paired with a stop or the process leaks a kernel resource per call,
//     which is why `withAccess` exists and why callers should prefer it.
//
// This type deliberately holds NO cached state: every call reads the bookmark back
// out of `UserDefaults`. That is what makes it a `Sendable` value usable from the
// main actor (the Settings row) and from a background task (the scanner) without a
// lock, an actor hop, or a class whose deinit could run off the main actor.

/// Where this device stands with respect to the vault folder.
public enum VaultFolderStatus: Sendable {
    /// No folder has ever been picked on this device (or it was forgotten).
    case notSet
    /// A folder is held and resolved to this URL.
    case ready(URL)
    /// A bookmark exists but the folder it names is gone or has moved beyond what
    /// the bookmark can follow. The user has to pick it again.
    case stale
    /// A bookmark exists and resolving it failed for some other reason.
    ///
    /// The common cause on macOS is not corruption but IDENTITY: a security-scoped
    /// bookmark is bound to the code signature of the app that created it, so a build
    /// signed differently from the one that picked the folder cannot resolve the
    /// bookmark it left behind and reports it as malformed. Observed directly while
    /// building this: rebuilding an unsigned binary turned a working bookmark into
    /// "the file couldn't be opened because it isn't in the correct format".
    case unreadable(String)

    /// A short line for the diagnostics screen and the Settings row.
    ///
    /// Every failing state names the SAME ACTION, because it is the same action:
    /// pick the folder again. A status line on a diagnostics screen that reports a
    /// Foundation error string and leaves the reader to infer what to do is a line
    /// that has not done its job.
    public var display: String {
        switch self {
        case .notSet: return "Not set"
        case .ready(let url): return "Ready — \(url.lastPathComponent)"
        case .stale: return "Stale — pick the folder again"
        case .unreadable(let reason): return "Pick the folder again — \(reason)"
        }
    }

    /// True when the folder has to be picked again before anything can be read.
    public var needsPicking: Bool {
        switch self {
        case .ready: return false
        case .notSet, .stale, .unreadable: return true
        }
    }

    /// The resolved URL when there is one. Nil in every other state.
    public var url: URL? {
        if case .ready(let url) = self { return url }
        return nil
    }

    public var isReady: Bool { url != nil }
}

public enum VaultFolderError: Error, CustomStringConvertible {
    case noFolderHeld
    case bookmarkStale
    case accessDenied(String)

    public var description: String {
        switch self {
        case .noFolderHeld: return "No vault folder has been picked on this device."
        case .bookmarkStale: return "The saved folder bookmark is stale — pick the folder again."
        case .accessDenied(let reason): return "The folder could not be opened: \(reason)"
        }
    }
}

/// Holds one folder across relaunches and reboots, and hands it out only inside a
/// balanced access bracket.
///
/// `@unchecked Sendable` for ONE reason, named rather than waved through:
/// `UserDefaults` is documented thread-safe but is not annotated `Sendable` in the
/// SDK, so the compiler cannot see what the documentation says. Nothing else here is
/// mutable — there is no cached URL, no lazily resolved bookmark, no stored status —
/// which is what makes the claim true rather than merely asserted.
public struct VaultFolder: @unchecked Sendable {
    /// The single `UserDefaults` key. One folder per device by design: the vault is
    /// one folder, and a list of them would be a feature nobody asked for.
    public static let defaultsKey = "jesse.vault.folderBookmark"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = VaultFolder.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// True when a bookmark is stored, whatever it currently resolves to.
    public var hasBookmark: Bool { defaults.data(forKey: key) != nil }

    /// Take a persistent bookmark to `url` — the URL a document picker or an open
    /// panel just handed over.
    ///
    /// The access bracket here is BALANCED: this method starts access only so the
    /// bookmark can be created, and stops again before returning. The caller gets
    /// live access by going through `resolve()` or `withAccess` afterwards, which is
    /// the same path every later launch takes, so the first run is not a special case
    /// that happens to work for a reason later runs do not share.
    public func adopt(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Self.bookmarkData(for: url)
            defaults.set(data, forKey: key)
        } catch {
            throw VaultFolderError.accessDenied(error.localizedDescription)
        }
    }

    /// Rebuild the folder URL from the stored bookmark, refreshing it when the system
    /// reports it stale, and START access to it.
    ///
    /// The start is deliberately NOT balanced here: this is the "hold the folder for
    /// the life of this launch" call the Settings row and the diagnostics screen use,
    /// and a stop would take the access away again before anything could read a file.
    /// Code that reads or writes should use `withAccess`, which is balanced; this is
    /// for asking "where do we stand".
    public func resolve() -> VaultFolderStatus {
        guard let data = defaults.data(forKey: key) else { return .notSet }
        var stale = false
        let url: URL
        do {
            url = try Self.resolveBookmark(data, stale: &stale)
        } catch {
            return .unreadable(error.localizedDescription)
        }
        if stale {
            // A stale bookmark can often be re-minted from the URL it still produced.
            // If that works the user never sees the staleness; if it does not, it is
            // a real "pick it again", not a transient error.
            guard url.startAccessingSecurityScopedResource() else { return .stale }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let refreshed = try? Self.bookmarkData(for: url) else { return .stale }
            defaults.set(refreshed, forKey: key)
        }
        guard url.startAccessingSecurityScopedResource() else {
            // A folder inside the app's own container needs no security scope and
            // legitimately returns false here, so this is not automatically a failure:
            // report ready when the folder is actually reachable.
            return FileManager.default.fileExists(atPath: url.path)
                ? .ready(url)
                : .stale
        }
        return .ready(url)
    }

    /// The current status without any intent to read — the Settings row's value.
    public var status: VaultFolderStatus { resolve() }

    /// Drop the bookmark. The folder itself is untouched.
    public func forget() {
        defaults.removeObject(forKey: key)
    }

    /// Run `body` with the folder URL inside a BALANCED security-scope bracket.
    ///
    /// This is the only access path that cannot leak: start and stop are paired on
    /// every exit, including a throw from `body`.
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let data = defaults.data(forKey: key) else { throw VaultFolderError.noFolderHeld }
        var stale = false
        let url: URL
        do {
            url = try Self.resolveBookmark(data, stale: &stale)
        } catch {
            throw VaultFolderError.accessDenied(error.localizedDescription)
        }
        if stale, url.startAccessingSecurityScopedResource() {
            if let refreshed = try? Self.bookmarkData(for: url) {
                defaults.set(refreshed, forKey: key)
            }
            url.stopAccessingSecurityScopedResource()
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if !scoped, !FileManager.default.fileExists(atPath: url.path) {
            throw VaultFolderError.bookmarkStale
        }
        return try body(url)
    }

    // MARK: - The two platform-conditional halves

    /// Creation options. macOS requires `.withSecurityScope` for a bookmark that
    /// survives relaunch; iOS has no equivalent for a document-picker URL and a
    /// default-options bookmark is the persistent one there.
    private static func bookmarkData(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope],
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
        #else
        return try url.bookmarkData(options: [],
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
        #endif
    }

    /// Resolution options, symmetric with `bookmarkData(for:)` — an asymmetry here
    /// is the classic way a bookmark resolves to a URL that cannot be opened.
    private static func resolveBookmark(_ data: Data, stale: inout Bool) throws -> URL {
        #if os(macOS)
        return try URL(resolvingBookmarkData: data,
                       options: [.withSecurityScope],
                       relativeTo: nil,
                       bookmarkDataIsStale: &stale)
        #else
        return try URL(resolvingBookmarkData: data,
                       options: [],
                       relativeTo: nil,
                       bookmarkDataIsStale: &stale)
        #endif
    }
}
