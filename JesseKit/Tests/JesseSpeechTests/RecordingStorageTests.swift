import AVFoundation
import XCTest
@testable import JesseSpeech

// The "Jesse never keeps the audio" half of the feature.
//
// Everything here is about DELETION: which files survive a sweep, which do not, and the
// one window in which an audio file with no manifest is a hand-off in progress rather
// than litter. The rules are exercised against a real temporary directory rather than a
// mock file system, because the failure being guarded against is a real file left on a
// real disk.

final class RecordingHandoffStoreTests: XCTestCase {

    private var root: URL!
    private var store: RecordingHandoffStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        store = RecordingHandoffStore(directory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// A stand-in for the file the share sheet hands over. Contents are irrelevant here —
    /// this file is about custody, not decoding.
    private func sourceFile(named name: String = "memo.m4a") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("audio bytes".utf8).write(to: url)
        return url
    }

    private var fileNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    // MARK: - Custody

    func testStagingCopiesTheFileAndRecordsWhatItWas() throws {
        let source = try sourceFile(named: "Nuova registrazione 3.m4a")
        let record = try store.stage(copying: source,
                                     originalName: "Nuova registrazione 3.m4a",
                                     durationSeconds: 192)

        // A COPY, not a reference: the extension's URL is scoped to a process that is
        // about to be killed, so the original must still be there and ours must exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: record).path))
        XCTAssertEqual(record.originalName, "Nuova registrazione 3.m4a")
        XCTAssertEqual(record.durationSeconds, 192)
        XCTAssertEqual(record.fileExtension, "m4a")
    }

    func testPendingRoundTripsThroughTheManifestOldestFirst() throws {
        let old = try store.stage(copying: try sourceFile(), originalName: "first.m4a",
                                  durationSeconds: 10, arrivedAt: Date(timeIntervalSince1970: 1_000))
        let new = try store.stage(copying: try sourceFile(), originalName: "second.m4a",
                                  durationSeconds: 20, arrivedAt: Date(timeIntervalSince1970: 2_000))

        // A fresh store over the same directory — the app is a different process from the
        // extension, so nothing may be carried in memory.
        let reopened = RecordingHandoffStore(directory: root).pending()
        XCTAssertEqual(reopened.map(\.id), [old.id, new.id])
        XCTAssertEqual(reopened.map(\.originalName), ["first.m4a", "second.m4a"])
        XCTAssertEqual(reopened.first?.arrivedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testNoPartialFileSurvivesASuccessfulStage() throws {
        let record = try store.stage(copying: try sourceFile(), originalName: "memo.m4a",
                                     durationSeconds: 5)
        XCTAssertEqual(fileNames.sorted(), [record.audioFileName, record.manifestFileName].sorted())
    }

    func testDiscardRemovesBothHalves() throws {
        let record = try store.stage(copying: try sourceFile(), originalName: "memo.m4a",
                                     durationSeconds: 5)
        store.discard(record)
        XCTAssertEqual(fileNames, [])
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testAManifestWhoseAudioIsGoneIsNotOfferedAsPending() throws {
        let record = try store.stage(copying: try sourceFile(), originalName: "memo.m4a",
                                     durationSeconds: 5)
        try FileManager.default.removeItem(at: store.audioURL(for: record))
        XCTAssertTrue(store.pending().isEmpty,
                      "handing the app a record it cannot open would turn tidy-up into a failure")
    }

    // MARK: - The sweep

    func testSweepRemovesAManifestWithNoAudio() throws {
        let record = try store.stage(copying: try sourceFile(), originalName: "memo.m4a",
                                     durationSeconds: 5)
        try FileManager.default.removeItem(at: store.audioURL(for: record))
        store.sweep()
        XCTAssertEqual(fileNames, [])
    }

    func testSweepRemovesAnUnclaimedAudioFileOnceTheGraceWindowHasPassed() throws {
        // The crash case: a copy finished, the manifest write never happened. That audio
        // is a recording nobody will ever transcribe, and it must not stay on disk.
        let orphan = root.appendingPathComponent("\(UUID().uuidString).m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: orphan)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)],
                                              ofItemAtPath: orphan.path)
        store.sweep()
        XCTAssertEqual(fileNames, [])
    }

    func testSweepLeavesAFreshUnclaimedAudioFileAlone() throws {
        // The one moment this state is legitimate: the extension has copied and has not
        // yet written the manifest. Deleting here would lose a share that was about to
        // become valid.
        let inFlight = root.appendingPathComponent("\(UUID().uuidString).m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: inFlight)
        store.sweep()
        XCTAssertEqual(fileNames.count, 1)
    }

    func testSweepRemovesAPairThatWasNeverPickedUp() throws {
        // Shared, never opened, and now stale. The recording is still in Voice Memos,
        // which is where it belongs.
        _ = try store.stage(copying: try sourceFile(), originalName: "memo.m4a",
                            durationSeconds: 5,
                            arrivedAt: Date(timeIntervalSinceNow: -(25 * 60 * 60)))
        store.sweep()
        XCTAssertEqual(fileNames, [])
    }

    func testSweepKeepsAPairThatIsStillWaiting() throws {
        // The whole reason the inbox cannot simply be purged: this one is the user's
        // share, waiting for the app to be opened.
        let record = try store.stage(copying: try sourceFile(), originalName: "memo.m4a",
                                     durationSeconds: 5,
                                     arrivedAt: Date(timeIntervalSinceNow: -60))
        store.sweep()
        XCTAssertEqual(store.pending().map(\.id), [record.id])
    }

    func testSweepRemovesAnUnreadableManifest() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let junk = root.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: junk)
        store.sweep()
        XCTAssertEqual(fileNames, [])
    }
}

final class RecordingWorkingCopyTests: XCTestCase {

    private var root: URL!
    private var working: RecordingWorkingCopy!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("working-\(UUID().uuidString)", isDirectory: true)
        working = RecordingWorkingCopy(directory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testAdoptCopiesAndKeepsTheExtension() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("memo.m4a")
        try Data("audio".utf8).write(to: source)

        let copy = try working.adopt(copying: source)
        XCTAssertEqual(copy.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the original belongs to whoever recorded it")

        working.remove(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testPurgeEmptiesTheDirectory() throws {
        // The crash story for the picker path: nothing is legitimately in flight at
        // launch, so anything here is by definition abandoned.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.m4a", "b.wav", "c"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        working.purge()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testPurgeOnAMissingDirectoryIsHarmless() {
        RecordingWorkingCopy(directory: root.appendingPathComponent("nope")).purge()
    }
}

final class AudioFileProbeTests: XCTestCase {

    /// A real, tiny, silent WAV written with AVAudioFile — no microphone, no recognizer,
    /// no fixture checked into the repo. It proves the probe accepts genuine audio and
    /// measures it, which a fake probe by construction cannot.
    private func writeSilentWave(seconds: Double, sampleRate: Double = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    func testProbeMeasuresRealAudio() throws {
        let url = try writeSilentWave(seconds: 2.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = try AVAudioFileProbe().facts(forFileAt: url)
        XCTAssertEqual(facts.durationSeconds, 2.5, accuracy: 0.01)
        XCTAssertEqual(facts.sampleRate, 16_000, accuracy: 0.5)
    }

    func testProbeRejectsAFileThatIsNotAudio() throws {
        // "A file that is not audio, or is corrupt, is rejected with a specific message"
        // — and rejected HERE, by the same reader the transcriber uses, rather than
        // later as an opaque engine error.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).m4a")
        try Data("this is a text file wearing an m4a extension".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try AVAudioFileProbe().facts(forFileAt: url)) { error in
            XCTAssertEqual(error as? TranscriptionFailure, .unreadableFile)
        }
    }

    func testProbeRejectsAMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gone.m4a")
        XCTAssertThrowsError(try AVAudioFileProbe().facts(forFileAt: url)) { error in
            XCTAssertEqual(error as? TranscriptionFailure, .unreadableFile)
        }
    }

    func testTheAcceptedTypesCoverTheCommonRecorderOutputs() {
        let identifiers = Set(AudioRecordingTypes.contentTypes.map(\.identifier))
        XCTAssertTrue(identifiers.contains("public.mpeg-4-audio"))   // m4a — Voice Memos
        XCTAssertTrue(identifiers.contains("public.mp3"))
        XCTAssertTrue(identifiers.contains("com.microsoft.waveform-audio"))
        XCTAssertTrue(identifiers.contains("public.aiff-audio"))
        XCTAssertTrue(identifiers.contains("com.apple.coreaudio-format"))
    }
}
