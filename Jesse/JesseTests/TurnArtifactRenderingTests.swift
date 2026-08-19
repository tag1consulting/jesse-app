import XCTest
import SwiftData
@testable import Jesse
import JesseCore
import JesseNetworking

/// What a `TurnArtifact` says about how it should be DRAWN, and what the loader does with
/// its mime on the way to disk.
///
/// The bug behind all of it: the cache named every file with the bare hex id, so QuickLook
/// — which types a file from its extension and has no other way — opened every artifact
/// that was not a PNG or JPEG to a blank preview. SVG was in that group twice over, being
/// excluded from the inline path as well.
@MainActor
final class TurnArtifactRenderingTests: XCTestCase {

    private func artifact(_ mime: String, filename: String = "f") -> TurnArtifact {
        TurnArtifact(artifactID: "aa11", filename: filename, mime: mime,
                     byteCount: 1, sha256: "x")
    }

    /// The three image types draw inline; the six document types do not. SVG is the one
    /// that moved — it used to be a chip on the reasoning that it is markup and a
    /// rendering surface.
    func testIsInlineImageCoversTheThreeImageTypes() {
        for mime in ["image/png", "image/jpeg", "image/svg+xml"] {
            XCTAssertTrue(artifact(mime).isInlineImage, mime)
        }
        for mime in ["application/pdf", "text/html", "text/csv",
                     "application/json", "text/markdown", "text/plain"] {
            XCTAssertFalse(artifact(mime).isInlineImage, mime)
        }
    }

    /// The model and the wire type answer the same question the same way — they share one
    /// rule rather than each carrying a copy of it.
    func testModelAndWireTypeAgreeOnWhatDrawsInline() {
        for mime in ["image/png", "image/jpeg", "image/svg+xml", "application/pdf",
                     "text/html", "text/csv", "application/json", "text/markdown",
                     "text/plain", "application/zip"] {
            let wire = JesseArtifact(id: "aa11", filename: "f", mime: mime,
                                     bytes: 1, sha256: "x")
            XCTAssertEqual(artifact(mime).isInlineImage, wire.isInlineImage, mime)
        }
    }

    /// An SVG is still a picture in the chip's icon, which was already true and must stay
    /// true now that the same condition drives the inline path.
    func testTypeIconStillReadsAtAGlance() {
        XCTAssertEqual(artifact("image/svg+xml").typeIcon, "photo")
        XCTAssertEqual(artifact("image/png").typeIcon, "photo")
        XCTAssertEqual(artifact("application/pdf").typeIcon, "doc.richtext")
        XCTAssertEqual(artifact("text/csv").typeIcon, "tablecells")
        XCTAssertEqual(artifact("application/json").typeIcon, "curlybraces")
        XCTAssertEqual(artifact("text/html").typeIcon, "globe")
        XCTAssertEqual(artifact("text/markdown").typeIcon, "doc.plaintext")
        XCTAssertEqual(artifact("application/zip").typeIcon, "doc")
    }

    /// The extension is a function of the mime and NOTHING else. A row whose filename is
    /// hostile, or simply disagrees with its own bytes, gets the extension its mime says.
    func testCacheExtensionComesFromTheMimeAndNeverFromTheFilename() {
        XCTAssertEqual(artifact("image/png", filename: "../../etc/passwd").cacheFileExtension, "png")
        XCTAssertEqual(artifact("text/csv", filename: ".hidden").cacheFileExtension, "csv")
        XCTAssertEqual(artifact("application/pdf", filename: "a\u{0000}b.exe").cacheFileExtension, "pdf")
        // The bridge's sniffer believes the bytes when the extension lies, and so does this.
        XCTAssertEqual(artifact("text/plain", filename: "definitely.png").cacheFileExtension, "txt")
        XCTAssertNil(artifact("application/zip", filename: "archive.zip").cacheFileExtension)
        XCTAssertNil(artifact("", filename: "chart.png").cacheFileExtension)
    }

    /// A row persisted before this change reads its extension straight off the mime it
    /// already stored. Nothing was added to the schema, so there is nothing to migrate —
    /// which is the point of computing this rather than storing it.
    func testExtensionIsComputedFromAnExistingRowWithNoNewStoredProperty() throws {
        let container = try ModelContainer(
            for: jesseCurrentSchema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let turn = Turn(role: .jesse, text: "x")
        ctx.insert(turn)
        turn.artifacts.append(TurnArtifact(artifactID: "aa11", filename: "drawing.svg",
                                           mime: "image/svg+xml", byteCount: 40,
                                           sha256: "ab", sortIndex: 0))
        try ctx.save()

        let reloaded = try XCTUnwrap(try ctx.fetch(FetchDescriptor<TurnArtifact>()).first)
        XCTAssertEqual(reloaded.cacheFileExtension, "svg")
        XCTAssertTrue(reloaded.isInlineImage)
    }

    // MARK: - The loader

    /// The loader threads the row's mime into the cache, so the file lands under a name
    /// QuickLook can type. This is the end-to-end shape of the fix on the iOS path.
    func testLoaderCachesUnderTheExtendedName() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-loader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtifactCache(directory: dir)

        let row = TurnArtifact(artifactID: "aa11", filename: "report.pdf",
                               mime: "application/pdf", byteCount: 5, sha256: "x")
        let client = FakeArtifactClient(bytes: Data([1, 2, 3, 4, 5]))
        let loader = ArtifactLoader(cache: cache) { client }

        let state = await loader.load(row)
        guard case let .ready(url) = state else { return XCTFail("expected ready, got \(state)") }
        XCTAssertEqual(url.lastPathComponent, "aa11.pdf")
        XCTAssertFalse(row.isExpired)

        // Second load is a CACHE HIT — the lazy-fetch policy is untouched by any of this.
        let again = await loader.load(row)
        XCTAssertEqual(again, .ready(url))
        XCTAssertEqual(client.calls, 1, "a cached file is not re-downloaded")
    }

    /// And a file this device downloaded under the OLD name is served from the cache
    /// rather than fetched again — the migration, on the path a real row takes.
    func testLoaderMigratesALegacyCacheEntryInsteadOfRefetching() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jesse-loader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data([9, 9, 9, 9])
        try bytes.write(to: dir.appendingPathComponent("bb22", isDirectory: false))

        let row = TurnArtifact(artifactID: "bb22", filename: "data.csv",
                               mime: "text/csv", byteCount: 4, sha256: "x")
        let client = FakeArtifactClient(bytes: Data())
        let loader = ArtifactLoader(cache: ArtifactCache(directory: dir)) { client }

        let state = await loader.load(row)
        guard case let .ready(url) = state else { return XCTFail("expected ready, got \(state)") }
        XCTAssertEqual(url.lastPathComponent, "bb22.csv")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(client.calls, 0, "the bytes were already here — no round trip")
    }
}

/// The narrowest possible stand-in for the app's client: it answers `artifact(id:)` and
/// counts how often it was asked, which is what the fetching-policy assertions above need.
/// Everything else on the protocol is defaulted in its extension, so a fake that models
/// only the artifact channel behaves like a bridge that does nothing else.
@MainActor
private final class FakeArtifactClient: JesseClientProtocol {
    let bytes: Data
    var calls = 0

    init(bytes: Data) { self.bytes = bytes }

    func send(mode: JesseMode, text: String, sessionId: String?,
              conversationId: String, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseAttachment], requestId: UUID,
              model: String?) async throws -> JesseSendResult {
        .running(jobId: "job-1", conversationId: nil)
    }
    func result(jobId: String) async throws -> JesseResultState {
        .done(JesseReply(text: "", sessionId: nil))
    }
    func cancelJob(jobId: String) async throws {}
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func artifact(id: String) async throws -> Data {
        calls += 1
        return bytes
    }
}
