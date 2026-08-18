import XCTest
import JesseCore
@testable import JesseNetworking

/// What the cache calls a file, and what happens to the files a previous build named
/// differently.
///
/// The cache used to write the bare hex id with no extension, which is why QuickLook had
/// nothing to type a file from and every non-image opened blank. Naming is therefore the
/// fix, and these are its edges: the extension comes from the mime alone, the model's
/// filename reaches no path, and an entry already on disk under the old name is converted
/// rather than abandoned.
final class ArtifactCacheNamingTests: XCTestCase {

    private func tempCache(maxBytes: Int = ArtifactCache.defaultMaxBytes) -> ArtifactCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-artifact-naming-\(UUID().uuidString)", isDirectory: true)
        return ArtifactCache(directory: dir, maxBytes: maxBytes)
    }

    /// The round trip: stored under `<id>.<ext>`, and found there again.
    func testStoresAndRetrievesUnderTheExtendedName() throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        // Hex ids, because that is the only shape the cache accepts.
        for (id, mime, ext) in [("0a1b", "application/pdf", "pdf"),
                                ("2c3d", "text/csv", "csv"),
                                ("4e5f", "image/svg+xml", "svg"),
                                ("6a7b", "image/jpeg", "jpg")] {
            let bytes = Data(repeating: 9, count: 32)
            let url = try cache.store(id: id, mime: mime, data: bytes)
            XCTAssertEqual(url.lastPathComponent, "\(id).\(ext)")
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                           cache.directory.standardizedFileURL,
                           "and still inside the cache directory")
            XCTAssertEqual(cache.cached(id: id, mime: mime, expectedBytes: 32), url)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    /// A mime this build does not know writes the bare id, exactly as every artifact used
    /// to. Unknown is not an error; it is the pre-existing behavior, preserved.
    func testUnknownMimeStoresWithNoExtension() throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        let url = try cache.store(id: "abcd", mime: "application/zip", data: Data([1, 2, 3]))
        XCTAssertEqual(url.lastPathComponent, "abcd")
        XCTAssertNotNil(cache.cached(id: "abcd", mime: "application/zip", expectedBytes: 3))

        let empty = try cache.store(id: "beef", mime: "", data: Data([1]))
        XCTAssertEqual(empty.lastPathComponent, "beef")
    }

    /// THE MIGRATION. A file this device downloaded before the rename is found under the
    /// legacy name and MOVED into place — the bytes were paid for with a network round
    /// trip, and the orphan would otherwise hold cache budget against live files forever.
    func testLegacyExtensionlessEntryIsFoundAndMigrated() throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        // Exactly what an older build left behind: the bare id, no extension.
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let legacy = cache.directory.appendingPathComponent("aa11", isDirectory: false)
        let bytes = Data(repeating: 4, count: 64)
        try bytes.write(to: legacy)

        let hit = try XCTUnwrap(cache.cached(id: "aa11", mime: "application/pdf", expectedBytes: 64))
        XCTAssertEqual(hit.lastPathComponent, "aa11.pdf", "found AND renamed")
        XCTAssertEqual(try Data(contentsOf: hit), bytes, "the same bytes, not a re-download")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "and the orphan is gone rather than left holding budget")

        // Second lookup takes the ordinary path.
        XCTAssertEqual(cache.cached(id: "aa11", mime: "application/pdf", expectedBytes: 64), hit)
    }

    /// A legacy file only migrates if it is INTACT. The size check is what catches a write
    /// truncated by a crash or a full disk, and it applies to the old name too.
    func testTruncatedLegacyEntryIsNotMigrated() throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let legacy = cache.directory.appendingPathComponent("bb22", isDirectory: false)
        try Data(repeating: 4, count: 10).write(to: legacy)

        XCTAssertNil(cache.cached(id: "bb22", mime: "application/pdf", expectedBytes: 64),
                     "a truncated file is a miss, whichever name it is under")
    }

    /// A truncated file already sitting at the NEW name must not block the migration of a
    /// good one from the old name — the move would otherwise throw onto an existing path.
    func testMigrationReplacesATruncatedFileAtTheNewName() throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 5).write(
            to: cache.directory.appendingPathComponent("cc33.pdf", isDirectory: false))
        let good = Data(repeating: 7, count: 64)
        try good.write(to: cache.directory.appendingPathComponent("cc33", isDirectory: false))

        let hit = try XCTUnwrap(cache.cached(id: "cc33", mime: "application/pdf", expectedBytes: 64))
        XCTAssertEqual(hit.lastPathComponent, "cc33.pdf")
        XCTAssertEqual(try Data(contentsOf: hit), good)
    }

    /// A fresh download supersedes any legacy copy of the same id rather than leaving two.
    func testStoringRemovesTheLegacyCopy() throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let legacy = cache.directory.appendingPathComponent("dd44", isDirectory: false)
        try Data(repeating: 1, count: 8).write(to: legacy)

        try cache.store(id: "dd44", mime: "text/csv", data: Data(repeating: 2, count: 16))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertNotNil(cache.cached(id: "dd44", mime: "text/csv", expectedBytes: 16))

        // And `remove` takes both, so "forget this artifact" leaves nothing behind.
        try Data(repeating: 1, count: 8).write(to: legacy)
        cache.remove(id: "dd44", mime: "text/csv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertNil(cache.cached(id: "dd44", mime: "text/csv", expectedBytes: 16))
    }

    /// THE FILENAME NEVER REACHES THE PATH. The model chose that string; every layer
    /// beneath it keeps it out of every path, and adding an extension did not change that.
    /// The cache path is a function of the id and the mime, and of nothing else.
    func testTheModelsFilenameCannotInfluenceTheCachePath() throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        // There is no parameter to pass these through — which is the point, and this test
        // is what would fail if one were ever added. The hostile names are here so the
        // reason is legible at the call site.
        let hostile = ["../../etc/passwd", "..\u{0000}/evil.sh", ".hidden",
                       "/absolute.png", "chart.svg\u{0000}.png"]
        for filename in hostile {
            let item = ArtifactPreviewItem(url: URL(fileURLWithPath: "/tmp/aa11.png"),
                                           filename: filename, mime: "image/png")
            // Safe in a TITLE, which is drawn and never resolved.
            XCTAssertEqual(item.previewItemTitle, filename)
        }

        let url = try XCTUnwrap(cache.url(for: "aa11", mime: "image/png"))
        XCTAssertEqual(url.lastPathComponent, "aa11.png")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       cache.directory.standardizedFileURL)

        // And the id itself still gets the hex guard, unchanged by any of this.
        XCTAssertNil(cache.url(for: "../escape", mime: "image/png"))
        XCTAssertNil(cache.url(for: "aa/bb", mime: "image/png"))
        XCTAssertNil(cache.url(for: "AABB", mime: "image/png"))
        XCTAssertNil(cache.url(for: "aa\u{0000}bb", mime: "image/png"))
        XCTAssertNil(cache.url(for: ".", mime: "image/png"))
        XCTAssertThrowsError(try cache.store(id: "..", mime: "image/png", data: Data([1])))
    }

    /// The naming change must not have moved the eviction policy. A legacy entry counts
    /// against the cap like any other file, which is why migrating on hit is enough and no
    /// startup sweep is needed.
    func testLegacyEntriesStillCountTowardTheCap() throws {
        let cache = tempCache(maxBytes: 250)
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(
            to: cache.directory.appendingPathComponent("ee55", isDirectory: false))
        XCTAssertEqual(cache.totalBytes(), 100, "an extensionless file is visible to the sweep")

        Thread.sleep(forTimeInterval: 0.02)
        try cache.store(id: "ff66", mime: "image/png", data: Data(repeating: 1, count: 100))
        Thread.sleep(forTimeInterval: 0.02)
        try cache.store(id: "0077", mime: "image/png", data: Data(repeating: 1, count: 100))

        XCTAssertLessThanOrEqual(cache.totalBytes(), 250)
        XCTAssertNil(cache.cached(id: "ee55", mime: "application/pdf", expectedBytes: 100),
                     "the oldest went first, legacy name and all")
    }

    /// The resolver threads the mime through to the cache, so a downloaded file lands
    /// under the right name on the path a real turn actually takes.
    func testResolverCachesUnderTheExtendedName() async throws {
        let cache = tempCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        let state = await ArtifactResolver.resolve(
            id: "aa11", mime: "text/csv", byteCount: 5, filename: "data.csv",
            isExpired: false, cache: cache,
            fetch: { _ in Data([1, 2, 3, 4, 5]) })
        guard case let .ready(url) = state else { return XCTFail("expected ready, got \(state)") }
        XCTAssertEqual(url.lastPathComponent, "aa11.csv")

        // And the no-cache fallback carries the extension too — it feeds the same
        // QuickLook, and a temp file without one is the same blank preview.
        let noCache = await ArtifactResolver.resolve(
            id: "bb22", mime: "application/pdf", byteCount: 3, filename: "r.pdf",
            isExpired: false, cache: nil,
            fetch: { _ in Data([1, 2, 3]) })
        guard case let .ready(tmp) = noCache else { return XCTFail("expected ready") }
        XCTAssertEqual(tmp.pathExtension, "pdf")
        try? FileManager.default.removeItem(at: tmp)
    }
}
