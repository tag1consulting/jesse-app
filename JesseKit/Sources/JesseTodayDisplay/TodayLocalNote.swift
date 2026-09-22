import Foundation
import JesseNetworking
import JesseVault

// THE DAY'S NOTES WHEN THE BRIDGE CANNOT BE REACHED.
//
// `GET /jesse/today/items/{id}/detail` is keyed by ITEM ID and has deliberately no path
// parameter, which is the right shape for a reader behind a token but means that with the
// bridge unreachable an item's note is not merely stale — it is unreachable, while a
// complete synced copy of the same note sits in Obsidian's folder on the same device.
//
// So this is the local half of that one endpoint, and NOTHING MORE. It resolves an item's
// first wiki link against the local copy, reads it, and hands it back to the same detail
// sheet with a badge saying where it came from. Two things it deliberately does not do:
//
//   * IT DOES NOT PARSE THE DAY FILE. The bridge mints the item ids the whole screen and
//     the capture queue are keyed by; a second parser in Swift would drift from it within
//     a month. Offline, the typed day stays the cached snapshot.
//   * IT CARRIES NO BRIEF. The brief is written by an agent, not read off a note, so
//     "offline" means the note and only the note.

/// One note as it exists in the local copy of the vault.
public struct LocalVaultNote: Equatable, Sendable {
    /// Path relative to the vault folder.
    public var path: String
    /// The wiki target it was resolved from, so the sheet can say which link it followed.
    public var target: String
    public var markdown: String
    /// The local file's own modification time, which is the whole provenance story: a
    /// synced folder can be hours behind, and the reader is entitled to know.
    public var modified: Date?
    /// The note was longer than the cap and `markdown` is a prefix.
    public var truncated: Bool

    public init(path: String, target: String, markdown: String, modified: Date? = nil,
                truncated: Bool = false) {
        self.path = path
        self.target = target
        self.markdown = markdown
        self.modified = modified
        self.truncated = truncated
    }

    /// The note's file name, for a heading. Same rule as `TodayItemDetail.fileName`.
    public var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }

    /// The same 64 KB ceiling the bridge applies to a detail note, so the offline copy and
    /// the online one cut at the same place and a reader is not told a different story
    /// about the same file depending on the network.
    public static let byteLimit = 64 * 1024
}

/// Where a local note comes from. One requirement, so a test can fake the whole vault with
/// four lines.
public protocol TodayLocalNoteProviding: Sendable {
    /// The first of `targets` that resolves to a readable note in the local copy, or nil
    /// when none does — including when no folder is held on this device, which is an
    /// ordinary state and never an error.
    func localNote(forTargets targets: [String]) async -> LocalVaultNote?
}

/// Which notes an item could open, in the order they should be tried.
public enum TodayLocalTargets {

    /// The item's wiki targets.
    ///
    /// The wire item CARRIES them — `TodayItem.links` with `kind == "wiki"`, extracted by
    /// the bridge's own `extract_links` — so that is the first and normal answer. The
    /// fallback parses them out of the item's RAW markdown (`text`) rather than out of
    /// `lead`, and the reason is worth stating: `lead` is the display string, and the
    /// bridge strips markdown to build it, which turns `[[Projects/Perseido|the fibre
    /// company]]` into the words "the fibre company" with the target gone. Parsing the lead
    /// alone would therefore find nothing on exactly the items that have links. The lead is
    /// still parsed last, for the case of a hand-written line the bridge did not strip.
    public static func targets(for item: TodayItem) -> [String] {
        var out: [String] = []
        func push(_ target: String) {
            let normalized = VaultWikiLink.normalized(target)
            guard !normalized.isEmpty, !out.contains(normalized) else { return }
            out.append(normalized)
        }
        for link in item.links where link.isWiki { push(link.target) }
        if out.isEmpty {
            for target in VaultWikiLink.targets(in: item.text) { push(target) }
            for target in VaultWikiLink.targets(in: item.lead) { push(target) }
        }
        return out
    }
}

/// The real provider: the index for resolution, `VaultFile` for a coordinated read.
public struct VaultLocalNoteProvider: TodayLocalNoteProviding {
    private let source: VaultIndexSource

    public init(source: VaultIndexSource = .shared) {
        self.source = source
    }

    public func localNote(forTargets targets: [String]) async -> LocalVaultNote? {
        guard !targets.isEmpty else { return nil }
        let source = self.source
        // OFF THE MAIN ACTOR: this is a coordinated read of a file in a synced folder, and
        // on a cold index it is also a walk of the vault.
        return await Task.detached {
            guard source.folderStatus.isReady else { return nil }
            let index = try? source.index()
            var paths: [String: String] = [:]
            for target in targets {
                if let resolved = index?.resolve(target: target) { paths[target] = resolved }
            }
            if paths.isEmpty {
                // A COLD INDEX is the one case worth paying a walk for: the app may never
                // have been on the Vault tab, and "open the note" must not answer "index
                // the vault first". One scan, all targets retried against it.
                if let all = try? source.vaultFolder.withAccess({
                    VaultScanner().scan(root: $0).files.map(\.relativePath)
                }) {
                    for target in targets {
                        if let resolved = VaultWikiLink.resolve(target: target, among: all) {
                            paths[target] = resolved
                        }
                    }
                }
            }
            // In the ITEM's order, not the map's: the first link of an item is the one the
            // bridge would have resolved, and the offline copy must follow the same link.
            for target in targets {
                guard let path = paths[target] else { continue }
                guard let read = try? source.vaultFolder.withAccess({ root -> (String, Date?) in
                    let text = try VaultFile(root: root).read(relativePath: path)
                    let attributes = try? FileManager.default
                        .attributesOfItem(atPath: root.appendingPathComponent(path).path)
                    return (text, attributes?[.modificationDate] as? Date)
                }) else { continue }
                let (markdown, truncated) = VaultNoteDocument.truncate(
                    read.0, byteLimit: LocalVaultNote.byteLimit)
                return LocalVaultNote(path: path, target: target, markdown: markdown,
                                      modified: read.1, truncated: truncated)
            }
            return nil
        }.value
    }
}
